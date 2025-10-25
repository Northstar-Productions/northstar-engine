local NE = require(game.ReplicatedStorage.NorthstarEngine)

local service = NE.CreateComponent("service", {
    Context = "Server",
    Client = {},
    ClientConfig = {}
})

return service
