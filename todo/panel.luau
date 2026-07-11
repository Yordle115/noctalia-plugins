-- =============================================================================
--  panel.luau — To-Do  v0.1.1
--  Simple persistent to-do list. Storage: ~/.config/noctalia-todo/todos.json
--  (shared with the bar widget and the /todo launcher provider).
--
--  Layout mirrors yordle/music-yt: a single column — tab bar (Active / Done),
--  an add-task input, and ONE ui.scroll body. Keep it to a single scroll
--  region: multiple scroll regions break input focus.
--
--  Per-row buttons (toggle / pin / delete) dispatch through rowAct() via a
--  fixed pool of literal global handlers (onRowTogN / onRowPinN / onRowDelN).
--  _G is read-only in this sandbox, so the pool MUST stay declared literally —
--  see the end of this file. Lists cap their clickable rows at POOL.
-- =============================================================================

local DATA_DIR  = noctalia.expandPath("~/.config/noctalia-todo")
local TODO_FILE = DATA_DIR .. "/todos.json"
local POOL      = 60   -- size of the literal per-row handler pool below

-- ---------- shell quoting ----------
local function sq(s)
  s = tostring(s or "")
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- ---------- view state ----------
local TAB_ACTIVE = "active"
local TAB_DONE   = "done"

local state = {
  tab      = TAB_ACTIVE,
  todos    = {},   -- { {id, text, done, pinned, created} } in insertion order
  rows     = {},   -- todo ids in currently-rendered row order (rowAct target)
  status   = "",
  inputGen = 1,    -- bumped after each add: a new input key = a cleared field
}

-- forward declaration (helpers below close over it)
local render

local function newId()
  return tostring(noctalia.formatTime("%s")) .. "-" .. tostring(math.random(1, 99999))
end

-- ---------- persistence ----------
-- Reload on every open so tasks added via /todo show up.
local function loadData()
  noctalia.runAsync("mkdir -p " .. sq(DATA_DIR), function()
    noctalia.runAsync("cat " .. sq(TODO_FILE) .. " 2>/dev/null", function(res)
      local ok, parsed = pcall(function() return noctalia.json.decode(res.stdout or "") end)
      if ok and type(parsed) == "table" then state.todos = parsed end
      render()
    end)
  end)
end

local function saveData()
  local json = noctalia.json.encode(state.todos)
  noctalia.runAsync("mkdir -p " .. sq(DATA_DIR) .. "; printf '%s' " .. sq(json) .. " > " .. sq(TODO_FILE), nil)
end

-- ---------- helpers ----------
local function findTodo(id)
  for i, t in ipairs(state.todos) do
    if t.id == id then return i, t end
  end
  return nil
end

local function counts()
  local active, done = 0, 0
  for _, t in ipairs(state.todos) do
    if t.done then done = done + 1 else active = active + 1 end
  end
  return active, done
end

local function addTodo(text)
  text = noctalia.string.trim(text or "")
  if text == "" then return end
  table.insert(state.todos, {
    id = newId(), text = text, done = false, pinned = false,
    created = tostring(noctalia.formatTime("%s")),
  })
  saveData()
  state.tab = TAB_ACTIVE
  state.status = "Added"
  state.inputGen = state.inputGen + 1
  render()
end

-- =====================================================================
--  RENDER
-- =====================================================================

local function emptyNote(text)
  return ui.label({ text = text, fontSize = 13, color = "on_surface_variant", paddingV = 8 })
end

-- One task row: [toggle] [text] [pin?] [delete].
-- Buttons dispatch through the shared handler pool (rowAct at the bottom).
local function listRow(i, t)
  local kids = {
    ui.button({
      glyph = t.done and "circle-check" or "circle",
      variant = t.done and "primary" or "ghost",
      onClick = "onRowTog" .. i,
    }),
    ui.label({
      text = t.text, fontSize = 13, flexGrow = 1, maxLines = 2,
      color = t.done and "on_surface_variant" or "on_surface",
    }),
  }
  if not t.done then
    kids[#kids + 1] = ui.button({
      glyph = t.pinned and "pinned" or "pin",
      variant = t.pinned and "primary" or "ghost",
      onClick = "onRowPin" .. i,
    })
  end
  kids[#kids + 1] = ui.button({ glyph = "x", variant = "ghost", onClick = "onRowDel" .. i })
  return ui.row({ gap = 6, align = "center", key = state.tab .. "-" .. i }, kids)
end

-- Render a task list into rows, registering each id in state.rows so the
-- handler pool can map a row index back to the todo it belongs to.
local function buildRows(list)
  state.rows = {}
  local kids = {}
  for _, t in ipairs(list) do
    local i = #state.rows + 1
    if i > POOL then
      kids[#kids + 1] = ui.label({
        text = "…and " .. (#list - POOL) .. " more",
        fontSize = 11, color = "on_surface_variant", paddingV = 4,
      })
      break
    end
    state.rows[i] = t.id
    kids[#kids + 1] = listRow(i, t)
  end
  return kids
end

local function activeView()
  -- pinned tasks first, both groups in insertion order
  local list = {}
  for _, t in ipairs(state.todos) do
    if not t.done and t.pinned then list[#list + 1] = t end
  end
  for _, t in ipairs(state.todos) do
    if not t.done and not t.pinned then list[#list + 1] = t end
  end
  if #list == 0 then
    state.rows = {}
    return { emptyNote("All clear — add a task above.") }
  end
  return buildRows(list)
end

local function doneView()
  local list = {}
  for _, t in ipairs(state.todos) do
    if t.done then list[#list + 1] = t end
  end
  if #list == 0 then
    state.rows = {}
    return { emptyNote("Nothing done yet.") }
  end
  local kids = {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = #list .. " done", fontSize = 11, color = "on_surface_variant" }),
      ui.button({ text = "Clear", glyph = "trash", variant = "ghost", onClick = "onClearDone" }),
    }),
  }
  for _, k in ipairs(buildRows(list)) do kids[#kids + 1] = k end
  return kids
end

function render()
  local active, done = counts()
  local function tabBtn(id, label)
    return ui.button({
      text = label,
      variant = state.tab == id and "primary" or "ghost",
      onClick = "onTab_" .. id, flexGrow = 1,
    })
  end
  local kids = {
    ui.row({ gap = 4, align = "center" }, {
      tabBtn(TAB_ACTIVE, active > 0 and ("Active (" .. active .. ")") or "Active"),
      tabBtn(TAB_DONE, done > 0 and ("Done (" .. done .. ")") or "Done"),
      ui.button({ glyph = "x", variant = "ghost", onClick = "onClose" }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.input({ key = "new-task-" .. state.inputGen, placeholder = "Add a task…", flexGrow = 1, fontSize = 14, onSubmit = "onAdd" }),
    }),
  }
  local body = (state.tab == TAB_DONE) and doneView() or activeView()
  kids[#kids + 1] = ui.scroll({ flexGrow = 1, gap = 4 }, { ui.column({ gap = 2 }, body) })
  if state.status ~= "" then
    kids[#kids + 1] = ui.label({ text = state.status, fontSize = 11, color = "on_surface_variant" })
  end
  panel.render(ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, kids))
end

-- =====================================================================
--  CALLBACKS
-- =====================================================================

function onOpen()
  state.status = ""
  loadData()
  render()
end

function onClose() panel.close() end

function onAdd(text) addTodo(text) end

function onTab_active() state.tab = TAB_ACTIVE; render() end
function onTab_done() state.tab = TAB_DONE; render() end

function onClearDone()
  local kept, removed = {}, 0
  for _, t in ipairs(state.todos) do
    if t.done then removed = removed + 1 else kept[#kept + 1] = t end
  end
  state.todos = kept
  saveData()
  state.status = "Cleared " .. removed .. " done"
  render()
end

-- ---------------------------------------------------------------------
--  Per-row dispatch: slot 1 = toggle done, 2 = pin/unpin, 3 = delete.
--  state.rows maps the rendered row index back to a todo id.
-- ---------------------------------------------------------------------
local function rowAct(i, slot)
  local id = state.rows[i]
  if not id then return end
  local idx, t = findTodo(id)
  if not t then return end
  if slot == 1 then
    t.done = not t.done
    t.pinned = false
    state.status = t.done and "Done" or "Reopened"
  elseif slot == 2 then
    t.pinned = not t.pinned
  else
    table.remove(state.todos, idx)
    state.status = "Deleted"
  end
  saveData()
  render()
end

-- ---------------------------------------------------------------------
--  Literal handler pool (POOL rows × 3 slots). _G is read-only in this
--  sandbox, so these cannot be generated in a loop — keep them literal
--  and keep the count in sync with POOL above.
-- ---------------------------------------------------------------------
function onRowTog1() rowAct(1, 1) end function onRowPin1() rowAct(1, 2) end function onRowDel1() rowAct(1, 3) end
function onRowTog2() rowAct(2, 1) end function onRowPin2() rowAct(2, 2) end function onRowDel2() rowAct(2, 3) end
function onRowTog3() rowAct(3, 1) end function onRowPin3() rowAct(3, 2) end function onRowDel3() rowAct(3, 3) end
function onRowTog4() rowAct(4, 1) end function onRowPin4() rowAct(4, 2) end function onRowDel4() rowAct(4, 3) end
function onRowTog5() rowAct(5, 1) end function onRowPin5() rowAct(5, 2) end function onRowDel5() rowAct(5, 3) end
function onRowTog6() rowAct(6, 1) end function onRowPin6() rowAct(6, 2) end function onRowDel6() rowAct(6, 3) end
function onRowTog7() rowAct(7, 1) end function onRowPin7() rowAct(7, 2) end function onRowDel7() rowAct(7, 3) end
function onRowTog8() rowAct(8, 1) end function onRowPin8() rowAct(8, 2) end function onRowDel8() rowAct(8, 3) end
function onRowTog9() rowAct(9, 1) end function onRowPin9() rowAct(9, 2) end function onRowDel9() rowAct(9, 3) end
function onRowTog10() rowAct(10, 1) end function onRowPin10() rowAct(10, 2) end function onRowDel10() rowAct(10, 3) end
function onRowTog11() rowAct(11, 1) end function onRowPin11() rowAct(11, 2) end function onRowDel11() rowAct(11, 3) end
function onRowTog12() rowAct(12, 1) end function onRowPin12() rowAct(12, 2) end function onRowDel12() rowAct(12, 3) end
function onRowTog13() rowAct(13, 1) end function onRowPin13() rowAct(13, 2) end function onRowDel13() rowAct(13, 3) end
function onRowTog14() rowAct(14, 1) end function onRowPin14() rowAct(14, 2) end function onRowDel14() rowAct(14, 3) end
function onRowTog15() rowAct(15, 1) end function onRowPin15() rowAct(15, 2) end function onRowDel15() rowAct(15, 3) end
function onRowTog16() rowAct(16, 1) end function onRowPin16() rowAct(16, 2) end function onRowDel16() rowAct(16, 3) end
function onRowTog17() rowAct(17, 1) end function onRowPin17() rowAct(17, 2) end function onRowDel17() rowAct(17, 3) end
function onRowTog18() rowAct(18, 1) end function onRowPin18() rowAct(18, 2) end function onRowDel18() rowAct(18, 3) end
function onRowTog19() rowAct(19, 1) end function onRowPin19() rowAct(19, 2) end function onRowDel19() rowAct(19, 3) end
function onRowTog20() rowAct(20, 1) end function onRowPin20() rowAct(20, 2) end function onRowDel20() rowAct(20, 3) end
function onRowTog21() rowAct(21, 1) end function onRowPin21() rowAct(21, 2) end function onRowDel21() rowAct(21, 3) end
function onRowTog22() rowAct(22, 1) end function onRowPin22() rowAct(22, 2) end function onRowDel22() rowAct(22, 3) end
function onRowTog23() rowAct(23, 1) end function onRowPin23() rowAct(23, 2) end function onRowDel23() rowAct(23, 3) end
function onRowTog24() rowAct(24, 1) end function onRowPin24() rowAct(24, 2) end function onRowDel24() rowAct(24, 3) end
function onRowTog25() rowAct(25, 1) end function onRowPin25() rowAct(25, 2) end function onRowDel25() rowAct(25, 3) end
function onRowTog26() rowAct(26, 1) end function onRowPin26() rowAct(26, 2) end function onRowDel26() rowAct(26, 3) end
function onRowTog27() rowAct(27, 1) end function onRowPin27() rowAct(27, 2) end function onRowDel27() rowAct(27, 3) end
function onRowTog28() rowAct(28, 1) end function onRowPin28() rowAct(28, 2) end function onRowDel28() rowAct(28, 3) end
function onRowTog29() rowAct(29, 1) end function onRowPin29() rowAct(29, 2) end function onRowDel29() rowAct(29, 3) end
function onRowTog30() rowAct(30, 1) end function onRowPin30() rowAct(30, 2) end function onRowDel30() rowAct(30, 3) end
function onRowTog31() rowAct(31, 1) end function onRowPin31() rowAct(31, 2) end function onRowDel31() rowAct(31, 3) end
function onRowTog32() rowAct(32, 1) end function onRowPin32() rowAct(32, 2) end function onRowDel32() rowAct(32, 3) end
function onRowTog33() rowAct(33, 1) end function onRowPin33() rowAct(33, 2) end function onRowDel33() rowAct(33, 3) end
function onRowTog34() rowAct(34, 1) end function onRowPin34() rowAct(34, 2) end function onRowDel34() rowAct(34, 3) end
function onRowTog35() rowAct(35, 1) end function onRowPin35() rowAct(35, 2) end function onRowDel35() rowAct(35, 3) end
function onRowTog36() rowAct(36, 1) end function onRowPin36() rowAct(36, 2) end function onRowDel36() rowAct(36, 3) end
function onRowTog37() rowAct(37, 1) end function onRowPin37() rowAct(37, 2) end function onRowDel37() rowAct(37, 3) end
function onRowTog38() rowAct(38, 1) end function onRowPin38() rowAct(38, 2) end function onRowDel38() rowAct(38, 3) end
function onRowTog39() rowAct(39, 1) end function onRowPin39() rowAct(39, 2) end function onRowDel39() rowAct(39, 3) end
function onRowTog40() rowAct(40, 1) end function onRowPin40() rowAct(40, 2) end function onRowDel40() rowAct(40, 3) end
function onRowTog41() rowAct(41, 1) end function onRowPin41() rowAct(41, 2) end function onRowDel41() rowAct(41, 3) end
function onRowTog42() rowAct(42, 1) end function onRowPin42() rowAct(42, 2) end function onRowDel42() rowAct(42, 3) end
function onRowTog43() rowAct(43, 1) end function onRowPin43() rowAct(43, 2) end function onRowDel43() rowAct(43, 3) end
function onRowTog44() rowAct(44, 1) end function onRowPin44() rowAct(44, 2) end function onRowDel44() rowAct(44, 3) end
function onRowTog45() rowAct(45, 1) end function onRowPin45() rowAct(45, 2) end function onRowDel45() rowAct(45, 3) end
function onRowTog46() rowAct(46, 1) end function onRowPin46() rowAct(46, 2) end function onRowDel46() rowAct(46, 3) end
function onRowTog47() rowAct(47, 1) end function onRowPin47() rowAct(47, 2) end function onRowDel47() rowAct(47, 3) end
function onRowTog48() rowAct(48, 1) end function onRowPin48() rowAct(48, 2) end function onRowDel48() rowAct(48, 3) end
function onRowTog49() rowAct(49, 1) end function onRowPin49() rowAct(49, 2) end function onRowDel49() rowAct(49, 3) end
function onRowTog50() rowAct(50, 1) end function onRowPin50() rowAct(50, 2) end function onRowDel50() rowAct(50, 3) end
function onRowTog51() rowAct(51, 1) end function onRowPin51() rowAct(51, 2) end function onRowDel51() rowAct(51, 3) end
function onRowTog52() rowAct(52, 1) end function onRowPin52() rowAct(52, 2) end function onRowDel52() rowAct(52, 3) end
function onRowTog53() rowAct(53, 1) end function onRowPin53() rowAct(53, 2) end function onRowDel53() rowAct(53, 3) end
function onRowTog54() rowAct(54, 1) end function onRowPin54() rowAct(54, 2) end function onRowDel54() rowAct(54, 3) end
function onRowTog55() rowAct(55, 1) end function onRowPin55() rowAct(55, 2) end function onRowDel55() rowAct(55, 3) end
function onRowTog56() rowAct(56, 1) end function onRowPin56() rowAct(56, 2) end function onRowDel56() rowAct(56, 3) end
function onRowTog57() rowAct(57, 1) end function onRowPin57() rowAct(57, 2) end function onRowDel57() rowAct(57, 3) end
function onRowTog58() rowAct(58, 1) end function onRowPin58() rowAct(58, 2) end function onRowDel58() rowAct(58, 3) end
function onRowTog59() rowAct(59, 1) end function onRowPin59() rowAct(59, 2) end function onRowDel59() rowAct(59, 3) end
function onRowTog60() rowAct(60, 1) end function onRowPin60() rowAct(60, 2) end function onRowDel60() rowAct(60, 3) end
