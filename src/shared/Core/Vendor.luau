local Vendor = {}
Vendor._registry = {}
Vendor._instances = {}
Vendor._initOrder = nil

local Promise = require(script.Parent.Parent.Shared.Promise)

function Vendor:Register(name, definition)
    assert(not self._registry[name], string.format("Component '%s' already registered", name))

    self._registry[name] = {
        Name = name,
        Definition = definition,
        Dependencies = definition.Dependencies or {},
        Context = definition.Context,
        Priority = definition.Priority or 0,
    }
end

function Vendor:Resolve(name)
    if self._instances[name] then
        return self._instances[name]
    end

    error(string.format("Component '%s' not found or not initialized", name))
end

function Vendor:Has(name)
    return self._instances[name] ~= nil
end

function Vendor:InitializeAll(networkBridge)
    return Promise.new(function(resolve, reject)
        -- Build dependency graph and topological sort
        local sortedNames = self:_topologicalSort()

        if not sortedNames then
            reject("Circular dependency detected")
            return
        end

        -- Phase 1: Init all components
        for _, name in ipairs(sortedNames) do
            local entry = self._registry[name]
            local definition = entry.Definition

            -- Create instance (copy definition to allow adding methods)
            local instance = setmetatable({}, {__index = definition})
            self._instances[name] = instance

            -- Resolve dependencies
            local deps = {}
            for _, depName in ipairs(entry.Dependencies) do
                table.insert(deps, self:Resolve(depName))
            end

            -- Call Init with dependencies
            if definition.Init then
                local success, err = pcall(definition.Init, instance, table.unpack(deps))
                if not success then
                    reject(string.format("Failed to init '%s': %s", name, err))
                    return
                end
            end

            -- Setup networking if has Client table
            if definition.Client and networkBridge then
                networkBridge:SetupComponent(definition, instance)
            end
        end

        -- Phase 2: Start all components
        for _, name in ipairs(sortedNames) do
            local instance = self._instances[name]
            local definition = self._registry[name].Definition

            if definition.Start then
                local success, err = pcall(definition.Start, instance)
                if not success then
                    warn(string.format("[NE] Failed to start '%s': %s", name, err))
                end
            end
        end

        resolve()
    end)
end

function Vendor:Shutdown()
    return Promise.new(function(resolve)
        -- Shutdown in reverse order
        if self._initOrder then
            for i = #self._initOrder, 1, -1 do
                local name = self._initOrder[i]
                local instance = self._instances[name]
                local definition = self._registry[name].Definition

                if definition.Shutdown then
                    pcall(definition.Shutdown, instance)
                end
            end
        end

        self._instances = {}
        resolve()
    end)
end

function Vendor:_topologicalSort()
    local sorted = {}
    local visited = {}
    local visiting = {}

    local function visit(name)
        if visited[name] then return true end
        if visiting[name] then return false end -- Circular dependency

        visiting[name] = true

        local entry = self._registry[name]
        if entry then
            for _, dep in ipairs(entry.Dependencies) do
                if not visit(dep) then
                    return false
                end
            end
        end

        visiting[name] = nil
        visited[name] = true
        table.insert(sorted, name)
        return true
    end

    for name, _ in pairs(self._registry) do
        if not visit(name) then
            return nil -- Circular dependency
        end
    end

    self._initOrder = sorted
    return sorted
end

return Vendor
