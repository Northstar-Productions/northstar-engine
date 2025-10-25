local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NorthstarEngine = {
    Version = "1.0.0",
    _initialized = false,
}

-- Load core modules
local Vendor = require(script.Core.Vendor)
local EventBus = require(script.Core.EventBus)
local NetworkBridge = require(script.Core.NetworkBridge)

-- Expose core systems
NorthstarEngine.Vendor = Vendor
NorthstarEngine.EventBus = EventBus

--[[
    Creates a new component

    @param name string - Unique component name
    @param definition table - Component definition with:
        - Context: "Server" | "Client" | "Shared"
        - Dependencies: {string}? - Array of component names
        - Client: {}? - Table for client-callable methods
        - ClientConfig: {}? - Configuration for client methods
    @return table - Component definition for method declarations
]]
function NorthstarEngine.CreateComponent(name, definition)
    assert(type(name) == "string", "Component name must be a string")
    assert(type(definition) == "table", "Component definition must be a table")
    assert(definition.Context, "Component must specify Context: 'Server', 'Client', or 'Shared'")

    local context = definition.Context
    local isServer = RunService:IsServer()
    local isClient = RunService:IsClient()

    -- Validate context matches runtime
    if context == "Server" and not isServer then
        warn(string.format("[NE] Skipping server component '%s' on client", name))
        return {}
    end

    if context == "Client" and not isClient then
        warn(string.format("[NE] Skipping client component '%s' on server", name))
        return {}
    end

    -- Register with Vendor
    Vendor:Register(name, definition)

    -- Return definition so methods can be added to it
    return definition
end

--[[
    Gets a component instance (resolves from Vendor)

    @param name string - Component name
    @return table - Component instance
]]
function NorthstarEngine.GetComponent(name)
    return Vendor:Resolve(name)
end

--[[
    Initializes the framework and all registered components

    @param config table? - Optional configuration
    @return Promise<void>
]]
function NorthstarEngine:Start(config)
    if self._initialized then
        warn("[NE] Framework already initialized")
        return
    end

    config = config or {}

    print("[NE] Starting Northstar Engine v" .. self.Version)

    -- Initialize EventBus
    EventBus:Init()

    -- Initialize NetworkBridge
    NetworkBridge:Init(EventBus)

    -- Initialize all components
    return Vendor:InitializeAll(NetworkBridge):andThen(function()
        self._initialized = true
        EventBus:Publish("NorthstarReady", {})
        print("[NE] Northstar Engine ready!")
    end):catch(function(err)
        warn("[NE] Failed to initialize:", err)
    end)
end

--[[
    Gracefully shuts down the framework

    @return Promise<void>
]]
function NorthstarEngine:Shutdown()
    print("[NE] Shutting down Northstar Engine...")

    return Vendor:Shutdown():andThen(function()
        self._initialized = false
        print("[NE] Shutdown complete")
    end)
end

return NorthstarEngine
