local util = require('vim.lsp.util')
local bit = require("bit")
local api = vim.api

local config = {
    refresh_on_change = true,
    debounce = 400,
    priority = 300,
}
local active_refreshes = {}

-- Dict[bufnr, Dict[client_id, semantices]]
local semantic_cache_by_buf = setmetatable({}, {
    __index = function(t, b)
        local key = b > 0 and b or api.nvim_get_current_buf()
        return rawget(t, key)
    end,
})

-- Dict[client_id, namespace_is]
local namespaces = setmetatable({}, {
    __index = function(t, key)
        local value = api.nvim_create_namespace('vim_lsp_semantic:' .. key)
        rawset(t, key, value)
        return value
    end,
})


local __semantic_apply_edit = function(data, edit)
    local j = 1
    local new_data = edit.data

    for _ = 1, edit.deleteCount do
        table.remove(data, edit.start + 1)
    end

    for i = edit.start + 1, edit.start + #new_data do
        table.insert(data, i, new_data[j])
        j = j + 1
    end
end

local function __token_modifiers_parse(tms, tokenModifiers)
    local ret = {}
    local idx = 1

    while tms ~= 0 do
        if bit.band(tms, 1) ~= 0 then
            table.insert(ret, tokenModifiers[idx])
        end
        tms = bit.rshift(tms, 1)
        idx = idx + 1
    end
    return ret
end

local function __semantic_to_hl_group(token_type, token_modifiers)
    local hl_group = '@' .. token_type
    for _, tm in ipairs(token_modifiers) do
        hl_group = hl_group .. '.' .. tm
    end
    return hl_group
end

local function __safe_str_byteindex_enc(line, index, encoding)
    if index == 0 or encoding == 'utf-8' then
        return index
    end
    local ok, ret = pcall(util._str_byteindex_enc, line, index, encoding)
    if ok then
        return ret
    end
    return -1

end

local function __semantic_apply(semantic_ctx)
    local line_num = 0;
    local col_start_utf = 0;

    local data = semantic_ctx.data
    local bufnr = semantic_ctx.bufnr
    local legend = semantic_ctx.legend
    local client_name = semantic_ctx.client_name
    local ns_id = semantic_ctx.namespace
    local ext_mark_userdata_dict = {}

    local parse_and_add_highlight = function(deltaLine, deltaStartChar, length, tokenType, tokenModifiers)
        if deltaLine ~= 0 then
            col_start_utf = 0
        end
        line_num = line_num + deltaLine
        col_start_utf = col_start_utf + deltaStartChar

        local token_type = legend.tokenTypes[tokenType + 1]
        local token_modifiers = __token_modifiers_parse(tokenModifiers, legend.tokenModifiers)
        local line_str = api.nvim_buf_get_lines(bufnr, line_num, line_num + 1, false)[1]
        local col_start = semantic_ctx.str_byteindex_enc(line_str, col_start_utf)
        local col_end = semantic_ctx.str_byteindex_enc(line_str, col_start_utf + length)
        local text = string.sub(line_str, col_start + 1, col_end)
        local ext_mark_id = api.nvim_buf_set_extmark(bufnr, ns_id, line_num, col_start, {
            end_row = line_num,
            end_col = col_end,
            hl_group = config.semantic_to_hl_group(token_type, token_modifiers),
            priority = config.priority,
        })
        ext_mark_userdata_dict[ext_mark_id] = {
            text = text,
            source = client_name,
            tokenType = token_type,
            tokenModifiers = token_modifiers,
        }
    end

    api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
    for i = 1, #data, 5 do
        pcall(parse_and_add_highlight, data[i], data[i + 1], data[i + 2], data[i + 3], data[i + 4])
    end
    semantic_ctx.ext_mark_userdata = ext_mark_userdata_dict
end

local function __on_semantic(semantic_ctx, semantic)
    local resultId = semantic.resultId
    local data = semantic.data
    local edits = semantic.edits
    local updated = false

    semantic_ctx.resultId = resultId

    if resultId then
        semantic_ctx.method = 'textDocument/semanticTokens/full/delta'
        semantic_ctx.params.previousResultId = resultId
    end

    if data then
        semantic_ctx.data = data
        updated = true
    elseif edits and vim.tbl_isempty(edits) then
        table.sort(edits, function(a, b) return a.start > b.start end)
        for _, e in pairs(edits) do
            __semantic_apply_edit(semantic_ctx.data, e)
        end
        updated = true
    end

    if updated then
        __semantic_apply(semantic_ctx)
    end
end

local function __update(semantic_ctx)
    local bufnr = semantic_ctx.bufnr
    local client = semantic_ctx.client
    local client_id = semantic_ctx.client_id
    if active_refreshes[client_id] then
        return
    end
    active_refreshes[client_id] = true

    client.request(semantic_ctx.method, semantic_ctx.params,
        function(err, result)
            active_refreshes[client_id] = nil
            if err then
                -- TODO
                return
            end
            __on_semantic(semantic_ctx, result)
        end, bufnr)
end

local function __update_defer(semantic_ctx, bufnr, changedtick, timeout)
    timeout = timeout or config.debounce
    vim.defer_fn(
        function()
            if changedtick and changedtick ~= api.nvim_buf_get_changedtick(bufnr) then
                return
            end
            __update(semantic_ctx)
        end,
        timeout)
end

local M = {}

function M.refresh_buf_client(client, bufnr)
    bufnr = bufnr or api.nvim_get_current_buf()
    local client_id = client.id

    local semantic_tokens_provider = client.server_capabilities.semanticTokensProvider
    if not semantic_tokens_provider then
        return
    end
    if not semantic_tokens_provider.full then
        return
    end

    local semantic_by_client = semantic_cache_by_buf[bufnr]
    if not semantic_by_client then
        semantic_by_client = {}
        semantic_cache_by_buf[bufnr] = semantic_by_client
    end

    local semantic_ctx = semantic_by_client[client_id]
    if not semantic_ctx then
        semantic_ctx = {
            client_id = client_id,
            client_name = client.name,
            client = client,
            namespace = namespaces[client_id],
            legend = semantic_tokens_provider.legend,
            delta = type(semantic_tokens_provider.full) == "table" and semantic_tokens_provider.full.delta,
            str_byteindex_enc = function(line, index) return __safe_str_byteindex_enc(line, index, client.offset_encoding) end,

            bufnr = bufnr,
            method = 'textDocument/semanticTokens/full',
            params = {
                textDocument = util.make_text_document_params(bufnr),
            }
        }
        semantic_by_client[client_id] = semantic_ctx
        api.nvim_buf_attach(bufnr, false, {
            on_detach = function(b)
                semantic_cache_by_buf[b] = nil
            end,
            on_lines = function(_, b, changedtick) __update_defer(semantic_ctx, b, changedtick) end,
            on_changedtick = function(_, b, changedtick) __update_defer(semantic_ctx, b, changedtick) end,
        })
    end

    __update(semantic_ctx)
end

function M.refresh()
    local bufnr = api.nvim_get_current_buf()
    for _, client in pairs(vim.lsp.get_active_clients({ bufnr = bufnr, })) do
        M.refresh_buf_client(client, bufnr)
    end
end

config.semantic_to_hl_group = __semantic_to_hl_group

function M.setup(opt)
    if not opt then
        return
    end

    if opt.debounce then
        config.debounce = opt.debounce
    end

    if opt.priority then
        config.priority = opt.priority
    end

    if opt.semantic_to_hl_group then
        config.semantic_to_hl_group = opt.semantic_to_hl_group
    end

    if type(opt.refresh_on_change) == "boolean" then
        config.refresh_on_change = opt.refresh_on_change
    end
end

function M.show()
    local bufnr = api.nvim_get_current_buf()
    local start = api.nvim_win_get_cursor(0)
    local cur_lnum = start[1] - 1
    local cur_col = start[2]
    local result = { "# Semantic", }

    local semantic_by_client = semantic_cache_by_buf[bufnr]
    if not semantic_by_client then
        return
    end

    for _, semantic_ctx in pairs(semantic_by_client) do
        local ns_id = semantic_ctx.namespace
        local ext_mark = api.nvim_buf_get_extmarks(
            bufnr,
            ns_id,
            { cur_lnum, cur_col },
            { 0, 0 },
            { limit = 1, details = true }
        )[1]
        if ext_mark then
            local m_lnum = ext_mark[2]
            local m_col_start = ext_mark[3]
            local m_col_end = ext_mark[4].end_col
            if cur_lnum == m_lnum and cur_col >= m_col_start and cur_col < m_col_end then
                local m_userdata = semantic_ctx.ext_mark_userdata[ext_mark[1]]
                table.insert(result, '---')
                table.insert(result, string.format("source:         `%s`", m_userdata.source))
                table.insert(result, string.format("text:           `%s`", m_userdata.text))
                table.insert(result, string.format("hlGroup:        `%s`", ext_mark[4].hl_group))
                table.insert(result, string.format("tokenType:      `%s`", m_userdata.tokenType))
                table.insert(result, string.format("tokenModifiers: `%s`", table.concat(m_userdata.tokenModifiers, ", ")))
            end
        end
    end

    if #result > 1 then
        vim.lsp.util.open_floating_preview(
            result,
            "markdown",
            { border = "single", pad_left = 4, pad_right = 4 }
        )
    end
end

M.update_client_capabilities = function(client_capabilities)
    client_capabilities = client_capabilities or vim.lsp.protocol.make_client_capabilities()
    client_capabilities.semanticTokens = {
        dynamicRegistration = false,
        requests = {
            range = false,
            full = {
                delta = true,
            }
        },
        tokenTypes = {
            'namespace',
            'type',
            'class',
            'enum',
            'interface',
            'struct',
            'typeParameter',
            'parameter',
            'variable',
            'property',
            'enumMember',
            'event',
            'function',
            'method',
            'macro',
            'keyword',
            'modifier',
            'comment',
            'string',
            'number',
            'regexp',
            'operator',
            'decorator'
        },
        tokenModifiers = {
            'declaration',
            'definition',
            'readonly',
            'static',
            'deprecated',
            'abstract',
            'async',
            'modification',
            'documentation',
            'defaultLibrary'
        },
        formats = { 'relative' },
        overlappingTokenSupport = false,
        multilineTokenSupport = false,
        serverCancelSupport = false,
        augmentsSyntaxTokens = false,
    }

    return client_capabilities
end


return M
