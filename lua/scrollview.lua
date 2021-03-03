-- *************************************************
-- * Memoization
-- *************************************************

local cache = {}
local memoize = false

local function start_memoize()
  memoize = true
end

local function stop_memoize()
  memoize = false
end

local function reset_memoize()
  cache = {}
end

-- *************************************************
-- * Utils
-- *************************************************

-- Round to the nearest integer.
-- WARN: .5 rounds to the right on the number line, including for negatives
-- (which would not result in rounding up in magnitude).
-- (e.g., round(3.5) == 3, round(-3.5) == -3 != -4)
local function round(x)
  return math.floor(x + 0.5)
end

-- *************************************************
-- * Core
-- *************************************************

-- Closes the window, with special handling for floating windows to first
-- delete all folds in all buffers. Folds are local to the window, so this
-- doesn't have any side effects on folds in other windows. This is a
-- workaround for Neovim Issue #14040, which results in a memory leak
-- otherwise.
local function close_window(winid)
  local config = vim.api.nvim_win_get_config(winid)
  if config.relative ~= '' then
    local current_winid = vim.fn.win_getid(vim.fn.winnr())
    vim.api.nvim_set_current_win(winid)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        vim.api.nvim_win_set_buf(winid, bufnr)
        -- zE only works when 'foldmethod' is "manual" or "marker".
        vim.api.nvim_win_set_option(winid, 'foldmethod', 'manual')
        vim.cmd('silent! normal! zE')
      end
    end
    vim.fn.win_gotoid(current_winid)
  end
  vim.api.nvim_win_close(winid, true)
end


-- Creates a temporary floating window that can be used for computations
-- ---corresponding to the specified window---that require temporary cursor
-- movements (e.g., counting virtual lines, where all lines in a closed fold
-- are counted as a single line). This can be used instead of working in the
-- actual window, to prevent unintended side-effects that arise from moving the
-- cursor in the actual window, even when autocmd's are disabled with
-- eventignore=all and the cursor is restored (e.g., Issue #18: window
-- flickering when resizing with the mouse, Issue #19: cursorbind/scrollbind
-- out-of-sync). It's the caller's responsibility to close the workspace
-- window.
local function open_win_workspace(winid)
  local current_winid = vim.fn.win_getid(vim.fn.winnr())
  -- Make the target window active, so that its folds are inherited by the
  -- created floating window (this is necessary when there are multiple windows
  -- that have the same buffer, each window having different folds).
  vim.fn.win_gotoid(winid)
  local config = {
    relative = 'editor',
    focusable = false,
    width = math.max(1, vim.fn.winwidth(winid)),
    height = math.max(1, vim.fn.winheight(winid)),
    row = 0,
    col = 0
  }
  local bufnr = vim.fn.winbufnr(winid)
  local workspace_winid = vim.api.nvim_open_win(bufnr, false, config)
  -- Disable scrollbind and cursorbind on the workspace window so that diff
  -- mode and other functionality that utilizes binding (e.g., :Gdiff, :Gblame)
  -- can function properly.
  vim.api.nvim_win_set_option(workspace_winid, 'scrollbind', false)
  vim.api.nvim_win_set_option(workspace_winid, 'cursorbind', false)
  vim.fn.win_gotoid(current_winid)
  return workspace_winid
end

-- Advance the current window cursor to the start of the next virtual span,
-- returning the range of lines jumped over, and a boolean indicating whether
-- that range was in a closed fold. A virtual span is a contiguous range of
-- lines that are either 1) not in a closed fold or 2) in a closed fold. If
-- there is no next virtual span, the cursor is returned to the first line.
local function advance_virtual_span()
  local start = vim.fn.line('.')
  local foldclosedend = vim.fn.foldclosedend(start)
  if foldclosedend ~= -1 then
    -- The cursor started on a closed fold.
    if foldclosedend == vim.fn.line('$') then
      vim.cmd('keepjumps normal! gg')
    else
      vim.cmd('keepjumps normal! j')
    end
    return start, foldclosedend, true
  end
  local lnum = start
  while true do
    vim.cmd('keepjumps normal! zj')
    if lnum == vim.fn.line('.') then
      -- There are no more folds after the cursor. This is the last span.
      vim.cmd('keepjumps normal! gg')
      return start, vim.fn.line('$'), false
    end
    lnum = vim.fn.line('.')
    local foldclosed = vim.fn.foldclosed(lnum)
    if foldclosed ~= -1 then
      -- The cursor moved to a closed fold. The preceding line ends the prior
      -- virtual span.
      return start, lnum - 1, false
    end
  end
end

-- Returns the count of virtual lines between the specified start and end lines
-- (both inclusive), in the specified window. A closed fold counts as one
-- virtual line. '$' can be used as the end line, to represent the last line.
local function virtual_line_count(winid, start, _end)
  local memoize_key =
    table.concat({'virtual_line_count', winid, start, _end}, ':')
  if memoize and cache[memoize_key] then return cache[memoize_key] end
  local current_winid = vim.fn.win_getid(vim.fn.winnr())
  local workspace_winid = open_win_workspace(winid)
  vim.fn.win_gotoid(workspace_winid)
  if type(_end) == 'string' and _end == '$' then
    _end = vim.fn.line('$')
  end
  start = math.max(1, start)
  _end = math.min(vim.fn.line('$'), _end)
  local count = 0
  if _end >= start then
    vim.cmd('keepjumps normal! ' .. start .. 'G')
    while true do
      local range_start, range_end, fold = advance_virtual_span()
      range_end = math.min(range_end, _end)
      local delta = 1
      if not fold then
        delta = range_end - range_start + 1
      end
      count = count + delta
      if range_end == _end or vim.fn.line('.') == 1 then
        break
      end
    end
  end
  vim.fn.win_gotoid(current_winid)
  close_window(workspace_winid)
  if memoize then cache[memoize_key] = count end
  return count
end

-- Return the line at the approximate virtual proportion in the specified
-- window. If the result is in a closed fold, it is converted to the first line
-- in that fold.
local function virtual_proportion_line(winid, proportion)
  local memoize_key =
    table.concat({'virtual_proportion_line', winid, proportion}, ':')
  if memoize and cache[memoize_key] then return cache[memoize_key] end
  local current_winid = vim.fn.win_getid(vim.fn.winnr())
  local workspace_winid = open_win_workspace(winid)
  vim.fn.win_gotoid(workspace_winid)
  local line = 0
  local virtual_line = 0
  local prop = 0.0
  local virtual_line_count = virtual_line_count(winid, 1, '$')
  if virtual_line_count > 1 then
    vim.cmd('keepjumps normal! gg')
    while true do
      local range_start, range_end, fold = advance_virtual_span()
      local line_delta = range_end - range_start + 1
      local virtual_line_delta = 1
      if not fold then
        virtual_line_delta = line_delta
      end
      local prop_delta = virtual_line_delta / (virtual_line_count - 1)
      if prop + prop_delta >= proportion then
        local ratio = (proportion - prop) / prop_delta
        prop = prop + (ratio * prop_delta)
        line = line + round(ratio * line_delta) + 1
        break
      end
      line = line + line_delta
      virtual_line = virtual_line + virtual_line_delta
      prop = virtual_line / (virtual_line_count - 1)
      if vim.fn.line('.') == 1 then
        -- advance_virtual_span looped back to the beginning of the document.
        line = vim.fn.line('$')
        break
      end
    end
  end
  line = math.max(1, line)
  line = math.min(vim.fn.line('$'), line)
  local foldclosed = vim.fn.foldclosed(line)
  if foldclosed ~= -1 then
    line = foldclosed
  end
  vim.fn.win_gotoid(current_winid)
  close_window(workspace_winid)
  if memoize then cache[memoize_key] = line end
  return line
end

return {
  close_window = close_window,
  open_win_workspace = open_win_workspace,
  reset_memoize = reset_memoize,
  start_memoize = start_memoize,
  stop_memoize = stop_memoize,
  virtual_line_count = virtual_line_count,
  virtual_proportion_line = virtual_proportion_line
}
