-- asi.nlu.resources: builds (and caches) the core lexicon from the shipped DSL data modules.
local Lexicon = require("asi.nlu.lexicon")

local R = {}
R.MODULES = { "lex_core", "lex_rel", "lex_sense", "lex_typenoun", "lex_gaz" }

local cached
function R.core(fresh)
  if cached and not fresh then return cached end
  local lex = Lexicon.new()
  for _, m in ipairs(R.MODULES) do lex:load(require("asi.nlu.data." .. m), m) end
  lex:build_spell()
  if #lex.errors > 0 then error("core lexicon has errors:\n" .. table.concat(lex.errors, "\n", 1, math.min(#lex.errors, 10))) end
  cached = lex
  return lex
end

-- a dataset overlay: inherits everything, adds its own entities/relations/vocabulary
function R.overlay(core)
  core = core or R.core()
  local ov = Lexicon.new(core)
  return ov
end

return R
