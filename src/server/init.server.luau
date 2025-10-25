local NorthstarEngine = require(game.ReplicatedStorage.NorthstarEngine)

NorthstarEngine:Start()

local import = NorthstarEngine.Loader.load(script)
import("testing")
