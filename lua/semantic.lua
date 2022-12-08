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
function M.__semantic_to_hl_group(tt, tms, tokenTypes, tokenModifiers)
    local hl_group = { '@' .. tokenTypes[tt + 1] }
    local idx = 1

    while tms ~= 0 do
        if bit.band(tms, 1) ~= 0 then
            table.insert(hl_group, tokenModifiers[idx])
        end
        tms = bit.rshift(tms, 1)
        idx = idx + 1
    end
    return table.concat(hl_group, ".")
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

local function __get_parameters(bufnr, row, col_start, col_end, hl, offset_encoding)
    if col_start > 0 or col_end > 0 then
        local line = api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
        col_start = col_start and __safe_str_byteindex_enc(line, col_start, offset_encoding)
        col_end = col_end and __safe_str_byteindex_enc(line, col_end, offset_encoding)
    end
    return row, col_start, {
        end_col = col_end,
        hl_group = hl,
        priority = config.priority,
    }
end


local function _add_highlight(bufnr, ns_id, line, col_start, length, hl, offset_encoding)
    api.nvim_buf_set_extmark(
        bufnr,
        ns_id,
        __get_parameters(
            bufnr,
            line,
            col_start,
            col_start + length,
            hl,
            offset_encoding
        )
    )
end

---@private
function M._on_semantic_parse(data, legend, bufnr, client_id, offset_encoding)
    local line = 0;
    local col_start = 0;
    local ns_id = namespaces[client_id]

    local parse_and_add_highlight = function(deltaLine, deltaStartChar, length, tokenType, tokenModifiers)
        if deltaLine ~= 0 then
            col_start = 0
        end
        line = line + deltaLine
        col_start = col_start + deltaStartChar
        _add_highlight(bufnr, ns_id, line, col_start, length,
            M.__semantic_to_hl_group(tokenType, tokenModifiers, legend.tokenTypes, legend.tokenModifiers),
            offset_encoding)
    end

    api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
    for i = 1, #data, 5 do
        pcall(parse_and_add_highlight, data[i], data[i + 1], data[i + 2], data[i + 3], data[i + 4])
    end
end

---@private
function M._on_semantic(semantic, bufnr, client, legend)
    local client_id = client.id
    local semantic_info = nil
    local semantic_by_client = semantic_cache_by_buf[bufnr]

    if not semantic_by_client then
        semantic_by_client = { [client_id] = semantic }
        semantic_cache_by_buf[bufnr] = semantic_by_client

        api.nvim_buf_attach(bufnr, false, {
            on_detach = function(b)
                semantic_cache_by_buf[b] = nil
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
        M._on_semantic_parse(semantic_info.data, legend, bufnr, client_id, client.offset_encoding)
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
    local result = { "# Semantic" }

    for _, ns in pairs(namespaces) do
        local ext_mark = api.nvim_buf_get_extmarks(
            bufnr,
            ns,
            { cur_lnum, cur_col },
            { 0, 0 },
            { limit = 1, details = true }
        )[1]
        if ext_mark then
            print(vim.inspect(ext_mark))
            local m_lnum = ext_mark[2]
            local m_col_start = ext_mark[3]
            local m_col_end = ext_mark[4].end_col
            if cur_lnum == m_lnum and cur_col >= m_col_start and cur_col < m_col_end then
                table.insert(result, "* " .. ext_mark[4].hl_group)
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

return M
