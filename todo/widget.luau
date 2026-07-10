-- =============================================================================
--  widget.luau — bar widget for To-Do
--  Shows the number of open tasks; click toggles the panel.
--  Reads the same todos.json the panel and /todo launcher write.
-- =============================================================================

local TODO_FILE = noctalia.expandPath("~/.config/noctalia-todo/todos.json")

local function sq(s)
  s = tostring(s or "")
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local showCount = barWidget.getConfig("show_count") ~= false

function update()
  noctalia.setUpdateInterval(5000)

  noctalia.runAsync("cat " .. sq(TODO_FILE) .. " 2>/dev/null", function(res)
    local ok, todos = pcall(function() return noctalia.json.decode(res.stdout or "") end)
    if not ok or type(todos) ~= "table" then todos = {} end

    local open, lines = 0, {}
    for _, t in ipairs(todos) do
      if not t.done then
        open = open + 1
        if #lines < 5 then lines[#lines + 1] = "• " .. tostring(t.text or "") end
      end
    end

    barWidget.setGlyph("checklist")
    barWidget.setText((showCount and open > 0) and tostring(open) or "")
    if open == 0 then
      barWidget.setTooltip("To-Do — all clear")
    else
      barWidget.setTooltip("To-Do — " .. open .. " open\n" .. table.concat(lines, "\n"))
    end
  end)
end

function onClick()
  noctalia.togglePanel("yordle/todo:panel")
end
