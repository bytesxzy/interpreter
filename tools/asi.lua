-- usage: lua5.4 tools/asi.lua <interpret|interpret-eval|interpret-report|interpret-trace|interpret-memory|interpret-replay|help> [options]
package.path = (arg[0]:match("^(.*)/tools/[^/]*$") or ".") .. "/nlu/?.lua;" .. package.path
local CLI = require("asi.nlu.cli")
os.exit(CLI.run(arg))
