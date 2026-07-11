-- =============================================================================
--  search.luau — launcher provider (/todo)
--  "/todo buy milk" → an "Add" row plus matching open tasks (activate = mark
--  done). Reads/writes the same todos.json the panel and bar widget use.
-- =============================================================================

local DATA_DIR  = noctalia.expandPath("~/.config/noctalia-todo")
local TODO_FILE = DATA_DIR .. "/todos.json"

local function sq(s)
  s = tostring(s or "")
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function readTodos(cb)
  noctalia.runAsync("cat " .. sq(TODO_FILE) .. " 2>/dev/null", function(res)
    local ok, todos = pcall(function() return noctalia.json.decode(res.stdout or "") end)
    cb((ok and type(todos) == "table") and todos or {})
  end)
end

local function writeTodos(todos, cb)
  local json = noctalia.json.encode(todos)
  noctalia.runAsync("mkdir -p " .. sq(DATA_DIR) .. "; printf '%s' " .. sq(json) .. " > " .. sq(TODO_FILE), cb)
end

function onQuery(text)
  text = noctalia.string.trim(text or "")
  readTodos(function(todos)
    local results = {}
    if text ~= "" then
      results[#results + 1] = { id = "add\t" .. text, title = "Add: " .. text, glyph = "plus" }
    end
    local needle = text:lower()
    for _, t in ipairs(todos) do
      if #results >= 10 then break end
      if not t.done then
        local body = tostring(t.text or "")
        if needle == "" or body:lower():find(needle, 1, true) then
          results[#results + 1] = {
            id = "done\t" .. tostring(t.id),
            title = body,
            subtitle = "✓ Mark done",
            glyph = "circle-check",
          }
        end
      end
    end
    if #results == 0 then
      results = { { id = "_hint", title = "Type to add a task", glyph = "checklist" } }
    end
    launcher.setResults(text, results)
  end)
end

function onActivate(id)
  if id:sub(1, 1) == "_" then return end
  local action, payload = id:match("^(%a+)\t(.*)$")
  if not action or not payload or payload == "" then return end

  readTodos(function(todos)
    if action == "add" then
      local epoch = tostring(noctalia.formatTime("%s"))
      table.insert(todos, {
        id = epoch .. "-" .. tostring(math.random(1, 99999)),
        text = payload, done = false, pinned = false, created = epoch,
      })
      writeTodos(todos, function() noctalia.notify("To-Do", "Added: " .. payload) end)
    elseif action == "done" then
      for _, t in ipairs(todos) do
        if tostring(t.id) == payload then
          t.done = true
          t.pinned = false
          writeTodos(todos, function() noctalia.notify("To-Do", "Done: " .. tostring(t.text or "")) end)
          return
        end
      end
    end
  end)
end
