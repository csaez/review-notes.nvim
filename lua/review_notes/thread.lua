-- Shows a conversation (markdown lines from notes.lua) in a read-only buffer:
-- treesitter highlights the markdown, and a few extmarks swap the markup for
-- icons, with no markdown plugin. The icons are the ones used everywhere else
-- (`require("review_notes").style`).
local M = {}

--- Filetype of read-only conversation buffers (a picker preview): markdown to
--- treesitter (registered in ftdetect/), with its own name so a markdown
--- renderer can be enabled for threads alone.
M.thread_ft = "reviewthread"

local ns = vim.api.nvim_create_namespace("review_notes_thread")

--- Window options that make the concealed markup disappear.
---@param win integer
function M.style(win)
  vim.wo[win].conceallevel = 2
  vim.wo[win].concealcursor = "nvic"
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
end

--- Fill *buf* with *lines* and decorate them.
---@param buf integer
---@param lines string[]
function M.set(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  M.decorate(buf, lines)
end

--- Decorate *lines*, the first lines of *buf*, as a conversation.
---@param buf integer
---@param lines string[]
function M.decorate(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local style = require("review_notes").style
  local nf = require("review_notes.notes")
  local resolved = nf.RESOLVED_VIEW
  local unsent = { [nf.UNSENT_VIEW] = { style.send, " not sent yet" }, [nf.UNSENT_DRAFT_VIEW] = { style.draft, " draft, not sent" } }
  local function icon_at(row, st, text)
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      virt_text = { { st.icon .. text, st.hl } },
      virt_text_pos = "inline",
    })
  end
  for i, l in ipairs(lines) do
    local row = i - 1
    if l:match("^### ") then
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { end_col = 4, conceal = "" })
      icon_at(row, style.thread, " ")
    elseif l == resolved then
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { end_col = #l, conceal = "" })
      icon_at(row, style.resolved, " resolved")
    elseif unsent[l] then
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { end_col = #l, conceal = "" })
      icon_at(row, unsent[l][1], unsent[l][2])
    end
  end
end

return M
