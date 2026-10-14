-- asi.nlu.vfs: read-only virtual file layer over the files embedded in the ONE-FILE build (module asi.nlu.embedded).
-- In a source checkout the embedded table does not exist and every function degrades to "nothing is virtual": real files are used.
-- Inside the one-file build the project's own data (gold sets, held-out sets, calibration model, acceptance world, reports, tests, tools) is read from the
-- file itself, so the engine, its evaluation tools and its unit tests run from an empty directory.
--   V.read(path) / V.exists(path) / V.list(prefix)     normalised, project-relative lookups ("./data/eval/dev.cases" == "data/eval/dev.cases")
--   V.install() / V.uninstall()                        wrap io.open / io.lines so unmodified code that opens project paths sees the embedded files
-- Only paths under data/ tests/ tools/ reports/ nlu/ and README.md are virtual; embedded content wins over a real file of the same relative path
-- (the shipped, hash-verified data is what the one-file build evaluates), every other path goes to the real file system untouched.
local V = {}

local ROOTS = { "data/", "tests/", "tools/", "reports/", "nlu/" }

local function embedded()
  local ok, t = pcall(require, "asi.nlu.embedded")
  if ok and type(t) == "table" and type(t.files) == "table" then return t end
  return nil
end

function V.available() return embedded() ~= nil end

-- "./data/eval/dev.cases", "/some/where/data/eval/dev.cases" -> "data/eval/dev.cases" when that file is embedded; nil otherwise
function V.normalize(path)
  local e = embedded()
  if not e or type(path) ~= "string" then return nil end
  local p = path:gsub("^%./+", ""):gsub("//+", "/")
  if e.files[p] then return p end
  -- a path that ends with an embedded project path under an explicit root marker ("<anything>/data/eval/dev.cases")
  for _, root in ipairs(ROOTS) do
    local at = p:find("/" .. root, 1, true)
    if at then
      local rel = p:sub(at + 1)
      if e.files[rel] then return rel end
    end
  end
  return nil
end

function V.read(path)
  local e = embedded()
  if not e then return nil end
  local rel = V.normalize(path)
  return rel and e.files[rel] or nil
end

function V.exists(path) return V.read(path) ~= nil end

function V.list(prefix)
  local e = embedded()
  local out = {}
  if not e then return out end
  for p in pairs(e.files) do if not prefix or p:sub(1, #prefix) == prefix then out[#out + 1] = p end end
  table.sort(out)
  return out
end

---------------------------------------------------------------- an in-memory file object (read-only) with the parts of the io API the project uses
local MemFile = {}
MemFile.__index = MemFile

local function new_memfile(data, name)
  return setmetatable({ data = data, pos = 1, name = name, closed = false }, MemFile)
end

local function read_one(self, fmt)
  local d, p = self.data, self.pos
  if type(fmt) == "number" then
    if fmt == 0 then return (p <= #d) and "" or nil end
    if p > #d then return nil end
    local s = d:sub(p, p + fmt - 1)
    self.pos = p + #s
    return s
  end
  fmt = tostring(fmt or "l"):gsub("^%*", "")
  if fmt == "a" then
    local s = d:sub(p)
    self.pos = #d + 1
    return s
  elseif fmt == "l" or fmt == "L" then
    if p > #d then return nil end
    local nl = d:find("\n", p, true)
    local line
    if nl then
      line = d:sub(p, fmt == "L" and nl or nl - 1)
      self.pos = nl + 1
    else
      line = d:sub(p)
      self.pos = #d + 1
    end
    return line
  elseif fmt == "n" then
    local num = d:match("^%s*([%+%-]?%d+%.?%d*[eE]?[%+%-]?%d*)", p)
    if not num then return nil end
    local _, e2 = d:find("^%s*[%+%-]?%d+%.?%d*[eE]?[%+%-]?%d*", p)
    self.pos = e2 + 1
    return tonumber(num)
  end
  error("bad argument #1 to 'read' (invalid format)", 3)
end

function MemFile:read(...)
  if self.closed then error("attempt to use a closed file", 2) end
  local n = select("#", ...)
  if n == 0 then return read_one(self, "l") end
  local out = {}
  for i = 1, n do
    local v = read_one(self, (select(i, ...)))
    out[i] = v
    if v == nil then break end
  end
  return table.unpack(out, 1, n)
end

function MemFile:lines(...)
  local fmts = table.pack(...)
  return function()
    if fmts.n == 0 then return read_one(self, "l") end
    return self:read(table.unpack(fmts, 1, fmts.n))
  end
end

function MemFile:seek(whence, offset)
  whence = whence or "cur"
  offset = offset or 0
  local base = (whence == "set" and 0) or (whence == "end" and #self.data) or (self.pos - 1)
  local np = base + offset
  if np < 0 then return nil, "invalid seek", 22 end
  self.pos = np + 1
  return np
end

function MemFile:close() self.closed = true; return true end
function MemFile:write() return nil, "virtual file is read-only", 9 end
function MemFile:flush() return self end
function MemFile:setvbuf() return true end
MemFile.__name = "FILE*"
MemFile.__tostring = function(self) return "file (virtual " .. tostring(self.name) .. ")" end

---------------------------------------------------------------- install / uninstall
local saved

local function is_read_mode(mode) return mode == nil or mode == "r" or mode == "rb" or mode == "rt" end

function V.install()
  if saved or not V.available() then return false end
  local real_open, real_lines, real_type = io.open, io.lines, io.type
  saved = { open = real_open, lines = real_lines, type = real_type }
  io.open = function(path, mode)
    if is_read_mode(mode) then
      local rel = V.normalize(path)
      if rel then return new_memfile(embedded().files[rel], rel) end
    end
    return real_open(path, mode)
  end
  io.lines = function(path, ...)
    if path ~= nil then
      local rel = V.normalize(path)
      if rel then
        local mf = new_memfile(embedded().files[rel], rel)
        return mf:lines(...)
      end
    end
    return real_lines(path, ...)
  end
  io.type = function(x)
    if getmetatable(x) == MemFile then return x.closed and "closed file" or "file" end
    return real_type(x)
  end
  return true
end

function V.uninstall()
  if not saved then return end
  io.open, io.lines, io.type = saved.open, saved.lines, saved.type
  saved = nil
end

-- run fn(...) with the virtual layer installed (restored even on error)
function V.with(fn, ...)
  local installed = V.install()
  local res = table.pack(pcall(fn, ...))
  if installed then V.uninstall() end
  if not res[1] then error(res[2], 0) end
  return table.unpack(res, 2, res.n)
end

return V
