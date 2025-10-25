local Loader = {}

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

-- Global caches for maximum performance
local _moduleCache = {}        -- [modulePath] = requiredModule
local _pathIndex = {}          -- [containerPath][moduleName] = moduleScript
local _searchPathCache = {}    -- [scriptPath] = {searchPaths}
local _indexedContainers = {}  -- [containerPath] = true

--[[
    Creates an import function bound to a script's context

    Usage:
        local import = require(ReplicatedStorage.NorthstarEngine.Loader).load(script)
        local MyModule = import("MyModule")

    @param sourceScript Instance - The script importing modules
    @return function - Import function for this script's context
]]
function Loader.load(sourceScript)
    assert(typeof(sourceScript) == "Instance", "Loader.load() requires a script instance")

    -- Return a closure that captures the source script
    return function(moduleName)
        assert(type(moduleName) == "string", "Module name must be a string")
        return Loader._import(sourceScript, moduleName)
    end
end

--[[
    Internal: Imports a module with caching and intelligent search

    @param sourceScript Instance
    @param moduleName string - Can be "Module" or "Folder/Module"
    @return any - The required module
]]
function Loader._import(sourceScript, moduleName)
    -- Fast path: Check global cache first
    local cacheKey = sourceScript:GetFullName() .. "::" .. moduleName
    if _moduleCache[cacheKey] then
        return _moduleCache[cacheKey]
    end

    -- Find the module script
    local moduleScript = Loader._findModule(sourceScript, moduleName)

    if not moduleScript then
        error(string.format(
            "[Loader] Module '%s' not found\nSearched from: %s\nTip: Check module name spelling and location",
            moduleName,
            sourceScript:GetFullName()
        ), 2)
    end

    -- Require and cache
    local success, result = pcall(require, moduleScript)

    if not success then
        error(string.format(
            "[Loader] Error requiring module '%s': %s",
            moduleName,
            tostring(result)
        ), 2)
    end

    _moduleCache[cacheKey] = result
    return result
end

--[[
    Internal: Finds a module script using intelligent search

    Search strategy:
    1. Parse path (support "Folder/Subfolder/Module")
    2. Get context-aware search paths
    3. Check indexed paths first (O(1))
    4. Fall back to recursive search if needed

    @param sourceScript Instance
    @param moduleName string
    @return ModuleScript?
]]
function Loader._findModule(sourceScript, moduleName)
    -- Parse path components
    local pathParts = string.split(moduleName, "/")
    local targetName = pathParts[#pathParts]

    -- Get search paths for this script
    local searchPaths = Loader._getSearchPaths(sourceScript)

    -- Search each path
    for _, searchRoot in ipairs(searchPaths) do
        local current = searchRoot

        -- Navigate through folder hierarchy
        for i = 1, #pathParts - 1 do
            local folderName = pathParts[i]
            local folder = current:FindFirstChild(folderName)

            if not folder or not (folder:IsA("Folder") or folder:IsA("Configuration")) then
                -- Path doesn't exist in this search root, try next
                current = nil
                break
            end

            current = folder
        end

        if current then
            -- Try to find module in current location
            local found = Loader._findInContainer(current, targetName)
            if found then
                return found
            end
        end
    end

    return nil
end

--[[
    Internal: Finds a module within a container using index

    @param container Instance
    @param moduleName string
    @return ModuleScript?
]]
function Loader._findInContainer(container, moduleName)
    local containerPath = container:GetFullName()

    -- Build index if not exists
    if not _indexedContainers[containerPath] then
        Loader._indexContainer(container)
    end

    -- Lookup in index
    local index = _pathIndex[containerPath]
    if index then
        -- Try exact match
        local found = index[moduleName]
        if found then return found end

        -- Try with "Module" suffix
        found = index[moduleName .. "Module"]
        if found then return found end

        -- Try without "Module" suffix
        if moduleName:match("Module$") then
            local baseName = moduleName:sub(1, -7)
            found = index[baseName]
            if found then return found end
        end

        -- Try case-insensitive match
        local lowerName = moduleName:lower()
        for name, moduleScript in pairs(index) do
            if name:lower() == lowerName then
                return moduleScript
            end
        end
    end

    return nil
end

--[[
    Internal: Builds index of all modules in a container

    Performance: O(n) where n = children count
    Called once per container, results cached

    @param container Instance
]]
function Loader._indexContainer(container)
    local containerPath = container:GetFullName()

    if _indexedContainers[containerPath] then
        return -- Already indexed
    end

    local index = {}

    local function indexRecursive(parent, depth)
        -- Limit recursion depth to prevent infinite loops
        if depth > 10 then return end

        for _, child in ipairs(parent:GetChildren()) do
            if child:IsA("ModuleScript") then
                -- Index by exact name
                index[child.Name] = child

                -- Also index without "Module" suffix if present
                if child.Name:match("Module$") then
                    local baseName = child.Name:sub(1, -7)
                    if not index[baseName] then
                        index[baseName] = child
                    end
                end
            elseif child:IsA("Folder") or child:IsA("Configuration") then
                -- Recurse into folders
                indexRecursive(child, depth + 1)
            end
        end
    end

    indexRecursive(container, 0)

    _pathIndex[containerPath] = index
    _indexedContainers[containerPath] = true
end

--[[
    Internal: Gets context-aware search paths for a script

    Intelligence:
    - Detects if script is in ServerStorage, ServerScriptService, etc.
    - Builds appropriate search paths based on context
    - Caches results per script for performance

    @param sourceScript Instance
    @return {Instance} - Array of containers to search
]]
function Loader._getSearchPaths(sourceScript)
    local scriptPath = sourceScript:GetFullName()

    -- Check cache
    if _searchPathCache[scriptPath] then
        return _searchPathCache[scriptPath]
    end

    local paths = {}
    local isServer = RunService:IsServer()

    -- 1. Script's immediate parent (highest priority)
    if sourceScript.Parent then
        table.insert(paths, sourceScript.Parent)
    end

    -- 2. Script's ancestor directories (walk up tree)
    local ancestor = sourceScript.Parent
    while ancestor and ancestor ~= game do
        if ancestor:IsA("Folder") or ancestor:IsA("Configuration") then
            table.insert(paths, ancestor)
        end
        ancestor = ancestor.Parent

        -- Stop at service level
        if ancestor == ReplicatedStorage or ancestor == ServerStorage then
            break
        end
    end

    -- 3. ReplicatedStorage.Modules (shared modules)
    local sharedModules = ReplicatedStorage:FindFirstChild("Modules")
    if sharedModules then
        table.insert(paths, sharedModules)
    end

    -- 4. ReplicatedStorage root (for top-level modules)
    table.insert(paths, ReplicatedStorage)

    -- 5. Server-only paths (if on server)
    if isServer then
        local serverModules = ServerStorage:FindFirstChild("Modules")
        if serverModules then
            table.insert(paths, serverModules)
        end

        table.insert(paths, ServerStorage)
    end

    -- 6. NorthstarEngine.Shared (framework utilities)
    local neEngine = ReplicatedStorage:FindFirstChild("NorthstarEngine")
    if neEngine then
        local neShared = neEngine:FindFirstChild("Shared")
        if neShared then
            table.insert(paths, neShared)
        end

        local neComponents = neEngine:FindFirstChild("Components")
        if neComponents then
            table.insert(paths, neComponents)
        end
    end

    -- Cache and return
    _searchPathCache[scriptPath] = paths
    return paths
end

--[[
    Clears all caches (useful for hot-reloading during development)
]]
function Loader.ClearCache()
    _moduleCache = {}
    _pathIndex = {}
    _searchPathCache = {}
    _indexedContainers = {}
    warn("[Loader] All caches cleared")
end

--[[
    Gets statistics about the loader's cache state

    @return table - Stats about cache usage
]]
function Loader.GetStats()
    local moduleCount = 0
    for _ in pairs(_moduleCache) do
        moduleCount = moduleCount + 1
    end

    local indexedCount = 0
    local totalIndexed = 0
    for containerPath, index in pairs(_pathIndex) do
        indexedCount = indexedCount + 1
        for _ in pairs(index) do
            totalIndexed = totalIndexed + 1
        end
    end

    return {
        CachedModules = moduleCount,
        IndexedContainers = indexedCount,
        TotalIndexedModules = totalIndexed,
        SearchPathsCached = #_searchPathCache
    }
end

return Loader
