local Render = require("trouble.view.render")
local Util = require("trouble.util")

local M = {}
M.preview = nil ---@type {item:trouble.Item, win:number, buf: number, close:fun()}?

M.ns = vim.api.nvim_create_namespace("trouble.preview_highlight")
M.count_ns = vim.api.nvim_create_namespace("trouble.preview_count_virt_text")

function M.is_open()
  return M.preview ~= nil
end

function M.is_win(win)
  return M.preview and M.preview.win == win
end

function M.item()
  return M.preview and M.preview.item
end

function M.close()
  local preview = M.preview
  M.preview = nil
  if not preview then
    return
  end
  Render.reset(preview.buf)
  preview.close()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    pcall(vim.api.nvim_buf_clear_namespace, buf, M.ns, 0, -1)
    pcall(vim.api.nvim_buf_clear_namespace, buf, M.count_ns, 0, -1)
  end
end

--- Create a preview buffer for an item.
--- If the item has a loaded buffer, use that,
--- otherwise create a new buffer.
---@param item trouble.Item
---@param opts? {scratch?:boolean}
function M.create(item, opts)
  opts = opts or {}

  local buf = item.buf or vim.fn.bufnr(item.filename)

  if item.filename and vim.fn.isdirectory(item.filename) == 1 then
    vim.b[buf].filename = item.filename
    return
  end

  -- create a scratch preview buffer when needed
  if not (buf and vim.api.nvim_buf_is_loaded(buf)) then
    if opts.scratch then
      buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = "wipe"
      vim.bo[buf].buftype = "nofile"
      local lines = Util.get_lines({ path = item.filename, buf = item.buf })
      if not lines then
        return
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.b[buf].filename = item.filename
      local ft = item:get_ft(buf)
      if ft then
        local lang = vim.treesitter.language.get_lang(ft)
        if not pcall(vim.treesitter.start, buf, lang) then
          vim.bo[buf].syntax = ft
        end
      end
    else
      item.buf = vim.fn.bufadd(item.filename)
      buf = item.buf

      if not vim.api.nvim_buf_is_loaded(item.buf) then
        vim.fn.bufload(item.buf)
      end
      if not vim.bo[item.buf].buflisted then
        vim.bo[item.buf].buflisted = true
      end
    end
  end

  vim.diagnostic.show(nil, buf, nil, nil)
  return buf
end

---@param view trouble.View
---@param item trouble.Item
---@param opts? {scratch?:boolean}
function M.open(view, item, opts)
  if M.item() == item then
    return
  end
  if M.preview and M.preview.item.filename ~= item.filename then
    M.close()
  end

  if not M.preview then
    local buf = M.create(item, opts)
    if not buf then
      return
    end

    M.preview = M.preview_win(buf, view)

    require("guess-indent").set_from_buffer("trouble", buf)
    M.preview.buf = buf
    view:highlight(buf, M.preview.win, item.filename, M.ns, M.count_ns)
  end
  M.preview.item = item

  Render.reset(M.preview.buf)

  -- make sure we highlight at least one character
  local end_pos = { item.end_pos[1], item.end_pos[2] }

  -- highlight the line
  Util.set_extmark(M.preview.buf, Render.ns, item.pos[1] - 1, 0, {
    end_row = end_pos[1],
    hl_group = "CursorLine",
    hl_eol = true,
    strict = false,
    priority = 150,
  })

  -- no autocmds should be triggered. So LSP's etc won't try to attach in the preview
  Util.noautocmd(function()
    if pcall(vim.api.nvim_win_set_cursor, M.preview.win, item.pos) then
      vim.api.nvim_win_call(M.preview.win, function()
        vim.cmd("norm! zzzv")
      end)
    end
  end)

  if not require("config.utils").has_namespace("trouble.preview_highlight") then
    view:update_cur_highlight(M.preview.buf, M.preview.win, M.preview.item.filename, M.ns, M.count_ns)
  else
    view:highlight(M.preview.buf, M.preview.win, M.preview.item.filename, M.ns, M.count_ns)
  end

  _G.win_view = vim.api.nvim_win_call(M.preview.win, vim.fn.winsaveview)
  pcall(function(...)
    vim.defer_fn(function()
      if M.preview ~= nil then
        _G.indent_update(M.preview.win)
        require("treesitter-context").context_force_update(M.preview.buf, M.preview.win, true)
        vim.defer_fn(function()
          if M.preview ~= nil then
            _G.update_indent(true, M.preview.win)
            _G.indent_update(M.preview.win)
          end
        end, 20)
      end
    end, 40)
  end)
  return item
end

---@param buf number
---@param view trouble.View
function M.preview_win(buf, view)
  if view.opts.preview.type == "main" then
    local main = view:main()
    if not main then
      Util.debug("No main window")
      return
    end
    view.preview_win.opts.win = main.win
  else
    view.preview_win.opts.win = view.win.win
  end

  view.preview_win:open()
  Util.noautocmd(function()
    view.preview_win:set_buf(buf)
    view.preview_win:set_options("win")
    vim.w[view.preview_win.win].trouble_preview = true
  end)

  return {
    win = view.preview_win.win,
    close = function()
      view.preview_win:close()
    end,
  }
end

return M
