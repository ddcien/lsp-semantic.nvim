local util = require('vim.lsp.util')
local api = vim.api
local bit = require("bit")

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

---@private
function M._on_semantic_apply_edit(data, edit)
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

---@private
function M._on_semantic_parse(data, legend, bufnr, client_id)
    local line = 0;
    local col_start = 0;

    -- TODO: rename xx
    local xx = function(deltaLine, deltaStartChar, length, tokenType, tokenModifiers)

        if deltaLine ~= 0 then
            col_start = 0
        end
        line = line + deltaLine
        col_start = col_start + deltaStartChar

        api.nvim_buf_add_highlight(
            bufnr,
            namespaces[client_id],
            M.__semantic_to_hl_group(tokenType, tokenModifiers, legend.tokenTypes, legend.tokenModifiers),
            line,
            col_start,
            col_start + length)
    end

    for i = 1, #data, 5 do
        xx(data[i], data[i + 1], data[i + 2], data[i + 3], data[i + 4])
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

        local ns = namespaces[client_id]
        api.nvim_buf_attach(bufnr, false, {
            on_detach = function(b)
                semantic_cache_by_buf[b] = nil
            end,
            on_lines = function(_, b, _, first_lnum, last_lnum, last_lnum_new)
                api.nvim_buf_clear_namespace(b, ns, first_lnum, last_lnum)
                if (last_lnum_new >= last_lnum) then
                    M.refresh_buf_client(client, b)
                end
            end,
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
                M._on_semantic_apply_edit(old.data, e)
            end
            old.resultId = semantic.resultId
            semantic_info = old
        end
    end

    if semantic then
        M._on_semantic_parse(semantic_info.data, legend, bufnr, client_id)
    end
end

---@private
function M.refresh_buf_client(client, bufnr)
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

function M.show()
    local bufnr = api.nvim_get_current_buf()
    local start = api.nvim_win_get_cursor(0)
    local cur_lnum = start[1] - 1
    local cur_col = start[2]
    local result = { "# Semantic" }

    for _, client in pairs(vim.lsp.get_active_clients({ bufnr = bufnr, })) do
        local m = api.nvim_buf_get_extmarks(bufnr, namespaces[client.id], { cur_lnum, cur_col }, { 0, 0 },
            { limit = 1, details = true })
        if vim.tbl_isempty(m) then
        else
            m = m[1]
            local m_lnum = m[2]
            local m_col_start = m[3]
            local m_col_end = m[4].end_col
            local m_hl_group = m[4].hl_group
            if cur_lnum == m_lnum and cur_col >= m_col_start and cur_col < m_col_end then
                table.insert(result, "## " .. client.name)
                table.insert(result, "* " .. m_hl_group)
            end
        end
    end

    if #result > 1 then
        vim.lsp.util.open_floating_preview(result, "markdown", { border = "single", pad_left = 4, pad_right = 4 })
    end
end

return M
