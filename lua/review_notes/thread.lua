-- Shows a conversation (markdown lines from notes.lua) in a read-only buffer:
-- treesitter highlights the markdown, and a few extmarks swap the markup for
-- icons, with no markdown plugin. The icons are the ones used everywhere else
-- (`require("review_notes").style`).
local M = {}

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
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local style = require("review_notes").style
  local resolved = require("review_notes.notes").RESOLVED_VIEW
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
      -- A question from pi waits for my answer, like the `ask` gutter icon.
      local asks = l == "### @pi" and (lines[i + 1] or ""):match("^QUESTION:")
      icon_at(row, asks and style.ask or style.thread, " ")
    elseif l == resolved then
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { end_col = #l, conceal = "" })
      icon_at(row, style.resolved, " resolved")
    end
  end
end

return M
