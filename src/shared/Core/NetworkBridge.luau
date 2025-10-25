local NetworkBridge = {}
NetworkBridge._remotes = {}
NetworkBridge._rateLimits = {}

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Promise = require(script.Parent.Parent.Shared.Promise)

function NetworkBridge:Init(eventBus)
    self._eventBus = eventBus
    self._remotes = {}
    self._rateLimits = {}
end

function NetworkBridge:SetupComponent(componentDefinition, componentInstance)
    local clientTable = componentDefinition.Client

    if not clientTable or type(clientTable) ~= "table" then
        return
    end

    -- SERVER SIDE: Create RemoteFunctions and bind handlers
    if RunService:IsServer() then
        for methodName, method in pairs(clientTable) do
            if type(method) == "function" then
                self:_setupServerMethod(componentDefinition, componentInstance, methodName, method)
            end
        end
    end

    -- CLIENT SIDE: Replace methods with remote wrappers
    if RunService:IsClient() then
        for methodName, _ in pairs(clientTable) do
            if type(clientTable[methodName]) == "function" then
                self:_setupClientMethod(componentDefinition, componentInstance, methodName)
            end
        end
    end
end

function NetworkBridge:_setupServerMethod(componentDef, componentInstance, methodName, method)
    local remoteName = componentDef.Name .. "_" .. methodName

    -- Create remote
    local remote = Instance.new("RemoteFunction")
    remote.Name = remoteName
    remote.Parent = self:_getRemotesFolder()

    self._remotes[remoteName] = remote

    -- Get config for this method
    local config = componentDef.ClientConfig and componentDef.ClientConfig[methodName]

    -- Setup handler
    remote.OnServerInvoke = function(player, ...)
        -- Rate limiting
        if config and config.RateLimit then
            if not self:_checkRateLimit(player, remoteName, config.RateLimit) then
                return {Error = "Rate limited. Please try again later."}
            end
        end

        -- Validation
        if config and config.Validate then
            local valid, err = config.Validate(player, ...)
            if not valid then
                return {Error = err or "Invalid arguments"}
            end
        end

        -- Execute method
        local success, result = pcall(method, componentInstance, player, ...)

        if success then
            return result
        else
            warn(string.format("[NE] %s.Client:%s() error: %s",
                componentDef.Name, methodName, tostring(result)))
            return {Error = "Internal server error"}
        end
    end
end

function NetworkBridge:_setupClientMethod(componentDef, componentInstance, methodName)
    local remoteName = componentDef.Name .. "_" .. methodName
    local remotesFolder = ReplicatedStorage:WaitForChild("Remotes", 10)

    if not remotesFolder then
        warn("[NE] Remotes folder not found")
        return
    end

    local remote = remotesFolder:WaitForChild(remoteName, 10)

    if not remote then
        warn("[NE] Failed to find remote:", remoteName)
        return
    end

    -- Replace method with Promise-returning wrapper
    componentInstance[methodName] = function(self, ...)
        return Promise.new(function(resolve, reject)
            local success, result = pcall(function()
                return remote:InvokeServer(...)
            end)

            if not success then
                reject("Network error: " .. tostring(result))
            elseif result and result.Error then
                reject(result.Error)
            else
                resolve(result)
            end
        end)
    end
end

function NetworkBridge:_getRemotesFolder()
    local folder = ReplicatedStorage:FindFirstChild("Remotes")
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = "Remotes"
        folder.Parent = ReplicatedStorage
    end
    return folder
end

function NetworkBridge:_checkRateLimit(player, key, config)
    local userId = player.UserId
    local fullKey = userId .. "_" .. key

    if not self._rateLimits[fullKey] then
        self._rateLimits[fullKey] = {
            executions = {},
            lastCleanup = os.clock(),
        }
    end

    local tracker = self._rateLimits[fullKey]
    local now = os.clock()

    -- Clean old executions
    local windowStart = now - config.WindowSeconds
    local newExecutions = {}
    for _, timestamp in ipairs(tracker.executions) do
        if timestamp > windowStart then
            table.insert(newExecutions, timestamp)
        end
    end
    tracker.executions = newExecutions

    -- Check limit
    if #tracker.executions >= config.MaxExecutions then
        return false
    end

    -- Record this execution
    table.insert(tracker.executions, now)
    return true
end

return NetworkBridge
