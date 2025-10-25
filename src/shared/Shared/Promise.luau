--[[
    Promise.lua - Lightweight Promise implementation for Northstar Engine
    Based on the Promises/A+ specification

    Usage:
        Promise.new(function(resolve, reject)
            -- async work
            resolve(value)
        end):andThen(function(value)
            return nextValue
        end):catch(function(err)
            warn(err)
        end)
]]

local Promise = {}
Promise.__index = Promise

local Status = {
    Pending = "Pending",
    Resolved = "Resolved",
    Rejected = "Rejected",
}

function Promise.new(executor)
    local self = setmetatable({
        _status = Status.Pending,
        _value = nil,
        _handlers = {},
    }, Promise)

    local function resolve(value)
        if self._status ~= Status.Pending then return end

        self._status = Status.Resolved
        self._value = value

        for _, handler in ipairs(self._handlers) do
            if handler.onResolved then
                task.spawn(handler.onResolved, value)
            end
        end

        self._handlers = {}
    end

    local function reject(reason)
        if self._status ~= Status.Pending then return end

        self._status = Status.Rejected
        self._value = reason

        for _, handler in ipairs(self._handlers) do
            if handler.onRejected then
                task.spawn(handler.onRejected, reason)
            end
        end

        self._handlers = {}
    end

    task.spawn(function()
        local success, err = pcall(executor, resolve, reject)
        if not success then
            reject(err)
        end
    end)

    return self
end

function Promise:andThen(onResolved, onRejected)
    return Promise.new(function(resolve, reject)
        local function handleResolved(value)
            if not onResolved then
                resolve(value)
                return
            end

            local success, result = pcall(onResolved, value)
            if success then
                if Promise.is(result) then
                    result:andThen(resolve, reject)
                else
                    resolve(result)
                end
            else
                reject(result)
            end
        end

        local function handleRejected(reason)
            if not onRejected then
                reject(reason)
                return
            end

            local success, result = pcall(onRejected, reason)
            if success then
                resolve(result)
            else
                reject(result)
            end
        end

        if self._status == Status.Resolved then
            task.spawn(handleResolved, self._value)
        elseif self._status == Status.Rejected then
            task.spawn(handleRejected, self._value)
        else
            table.insert(self._handlers, {
                onResolved = handleResolved,
                onRejected = handleRejected,
            })
        end
    end)
end

function Promise:catch(onRejected)
    return self:andThen(nil, onRejected)
end

function Promise:finally(onFinally)
    return self:andThen(
        function(value)
            onFinally()
            return value
        end,
        function(reason)
            onFinally()
            error(reason)
        end
    )
end

function Promise:await()
    if self._status == Status.Resolved then
        return self._value
    elseif self._status == Status.Rejected then
        error(self._value)
    end

    local thread = coroutine.running()

    self:andThen(
        function(value)
            task.spawn(thread, true, value)
        end,
        function(reason)
            task.spawn(thread, false, reason)
        end
    )

    local success, value = coroutine.yield()

    if success then
        return value
    else
        error(value)
    end
end

function Promise.resolve(value)
    return Promise.new(function(resolve)
        resolve(value)
    end)
end

function Promise.reject(reason)
    return Promise.new(function(_, reject)
        reject(reason)
    end)
end

function Promise.all(promises)
    return Promise.new(function(resolve, reject)
        local results = {}
        local remaining = #promises

        if remaining == 0 then
            resolve(results)
            return
        end

        for i, promise in ipairs(promises) do
            promise:andThen(function(value)
                results[i] = value
                remaining = remaining - 1

                if remaining == 0 then
                    resolve(results)
                end
            end, reject)
        end
    end)
end

function Promise.race(promises)
    return Promise.new(function(resolve, reject)
        for _, promise in ipairs(promises) do
            promise:andThen(resolve, reject)
        end
    end)
end

function Promise.is(value)
    return type(value) == "table"
        and getmetatable(value) == Promise
end

function Promise.delay(seconds)
    return Promise.new(function(resolve)
        task.delay(seconds, resolve)
    end)
end

return Promise
