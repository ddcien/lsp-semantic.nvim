local util = require('vim.lsp.util')
local bit = require("bit")
local api = vim.api

local config = {
    refresh_on_change = true,
    debounce = 400,
    priority = 200,
}
local M = {}
local active_refreshes = {}

-- Dict[bufnr, Dict[ns_id, Dict[ext_id: ext_mark_userdata]]]
local extmark_userdata = {}

--- bufnr -> client_id -> semantices
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

---@private
M.__namespaces = namespaces

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

local on_semantic_apply_edit = function(data, edit)
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

---@private
function M.__semantic_to_hl_group(token_type, token_modifiers)
    local hl_group = '@' .. token_type
    for _, tm in ipairs(token_modifiers) do
        hl_group = hl_group .. '.' .. tm
    end
    return hl_group
end

---@private
local function token_modifiers_parse(tms, tokenModifiers)
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

---@private
function M._on_semantic_parse(data, legend, bufnr, client)
    local line = 0;
    local col_start = 0;
    local offset_encoding = client.offset_encoding
    local ns_id = namespaces[client.id]
    local ext_mark_userdata_dict = {}

    local parse_and_add_highlight = function(deltaLine, deltaStartChar, length, tokenType, tokenModifiers)
        if deltaLine ~= 0 then
            col_start = 0
        end
        line = line + deltaLine
        col_start = col_start + deltaStartChar

        local token_type = legend.tokenTypes[tokenType + 1]
        local token_modifiers = token_modifiers_parse(tokenModifiers, legend.tokenModifiers)
        local col_end = col_start + length
        local line_str = api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
        col_start = col_start and __safe_str_byteindex_enc(line_str, col_start, offset_encoding)
        col_end = col_end and __safe_str_byteindex_enc(line_str, col_end, offset_encoding)
        local text = string.sub(line_str, col_start + 1, col_end)

        ext_mark_userdata_dict[
            api.nvim_buf_set_extmark(
                bufnr,
                ns_id,
                line,
                col_start,
                {
                    end_col = col_end,
                    hl_group = M.__semantic_to_hl_group(token_type, token_modifiers),
                    priority = config.priority,
                })] = {
            text = text,
            source = client.name,
            tokenType = token_type,
            tokenModifiers = token_modifiers,
        }
    end

    api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
    for i = 1, #data, 5 do
        pcall(parse_and_add_highlight, data[i], data[i + 1], data[i + 2], data[i + 3], data[i + 4])
    end
    extmark_userdata[bufnr][ns_id] = ext_mark_userdata_dict
end

---@private
function M._on_semantic(semantic, bufnr, client, legend)
    local client_id = client.id
    local semantic_info = nil
    local semantic_by_client = semantic_cache_by_buf[bufnr]

    if not semantic_by_client then
        semantic_by_client = { [client_id] = semantic }
        semantic_cache_by_buf[bufnr] = semantic_by_client
        extmark_userdata[bufnr] = { [namespaces[client_id]] = {} }

        api.nvim_buf_attach(bufnr, false, {
            on_detach = function(b)
                semantic_cache_by_buf[b] = nil
                extmark_userdata[b] = nil
            end,
            on_lines = function(_, b, changedtick)
                M.refresh_buf_client_defer(client, b, changedtick)
            end,
            on_changedtick = function(_, b, changedtick)
                M.refresh_buf_client_defer(client, b, changedtick)
            end
        })
        semantic_info = semantic
    else
        if semantic.data then
            semantic_by_client[client_id] = semantic
            semantic_info = semantic
        else
            local old = semantic_by_client[client_id]
            local edits = semantic.edits

            table.sort(edits, function(a, b) return a.start > b.start end)
            for _, e in pairs(edits) do
                on_semantic_apply_edit(old.data, e)
            end
            old.resultId = semantic.resultId
            semantic_info = old
        end
    end

    if semantic_info then
        M._on_semantic_parse(semantic_info.data, legend, bufnr, client)
    end
end

function M.refresh_buf_client(client, bufnr, changedtick)
    if not changedtick or changedtick == api.nvim_buf_get_changedtick(bufnr) then
        M.__refresh_buf_client(client, bufnr)
    end
end

---@private
function M.refresh_buf_client_defer(client, bufnr, changedtick)
    if config.refresh_on_change then
        vim.defer_fn(function() M.refresh_buf_client(client, bufnr, changedtick) end, config.debounce)
    end
end

---@private
function M.__refresh_buf_client(client, bufnr)
    local client_id = client.id
    if active_refreshes[client_id] then
        return
    end
    active_refreshes[client_id] = true

    local method = 'textDocument/semanticTokens/full'
    local params = {
        textDocument = util.make_text_document_params(),
    }

    local semantic_tokens_provider = client.server_capabilities.semanticTokensProvider
    if not semantic_tokens_provider then
        return
    end
    if not semantic_tokens_provider.full then
        return
    end

    if type(semantic_tokens_provider.full) == "table" and semantic_tokens_provider.full.delta then
        local semantic_by_client = semantic_cache_by_buf[bufnr or api.nvim_get_current_buf()]
        if semantic_by_client then
            local semantic = semantic_by_client[client_id]
            if semantic and semantic.resultId then
                method = method .. "/delta"
                params.previousResultId = semantic.resultId
            end
        end
    end

    client.request(method, params,
        function(err, result)
            active_refreshes[client_id] = nil
            if err then
                return
            end
            M._on_semantic(result, bufnr, client, semantic_tokens_provider.legend)
        end, bufnr)
end

function M.refresh()
    local bufnr = api.nvim_get_current_buf()
    for _, client in pairs(vim.lsp.get_active_clients({ bufnr = bufnr, })) do
        M.refresh_buf_client(client, bufnr)
    end
end

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

    if type(opt.refresh_on_change) == "boolean" then
        config.refresh_on_change = opt.refresh_on_change
    end
end

function M.show()
    local bufnr = api.nvim_get_current_buf()
    local start = api.nvim_win_get_cursor(0)
    local cur_lnum = start[1] - 1
    local cur_col = start[2]
    local result = { "# Semantic", '---', }

    for _, ns in pairs(namespaces) do
        local ext_mark_userdata_dict = extmark_userdata[bufnr][ns]
        local ext_mark = api.nvim_buf_get_extmarks(
            bufnr,
            ns,
            { cur_lnum, cur_col },
            { 0, 0 },
            { limit = 1, details = true }
        )[1]

        if ext_mark then
            local m_lnum = ext_mark[2]
            local m_col_start = ext_mark[3]
            local m_col_end = ext_mark[4].end_col
            if cur_lnum == m_lnum and cur_col >= m_col_start and cur_col < m_col_end then
                local m_userdata = ext_mark_userdata_dict[ext_mark[1]]
                table.insert(result, string.format("source:         %s", m_userdata.source))
                table.insert(result, string.format("text:           %s", m_userdata.text))
                table.insert(result, string.format("hlGroup:        %s", ext_mark[4].hl_group))
                table.insert(result, string.format("tokenType:      %s", m_userdata.tokenType))
                table.insert(result, string.format("tokenModifiers: %s", table.concat(m_userdata.tokenModifiers, ", ")))
            end
        end
    end

    if #result > 2 then
        vim.lsp.util.open_floating_preview(
            result,
            "markdown",
            { border = "single", pad_left = 4, pad_right = 4 }
        )
    end
end

return M
