local EventBus = {}
EventBus._handlers = {}

function EventBus:Init()
    self._handlers = {}
end

function EventBus:Publish(eventName, eventData)
    local handlers = self._handlers[eventName]
    if not handlers then return end

    local event = {
        Name = eventName,
        Data = eventData or {},
        Timestamp = os.clock(),
    }

    for _, handler in ipairs(handlers) do
        task.spawn(function()
            local success, err = pcall(handler, event)
            if not success then
                warn(string.format("[EventBus] Error in handler for '%s': %s", eventName, err))
            end
        end)
    end
end

function EventBus:Subscribe(eventName, handler)
    assert(type(handler) == "function", "Handler must be a function")

    if not self._handlers[eventName] then
        self._handlers[eventName] = {}
    end

    table.insert(self._handlers[eventName], handler)

    local connection = {
        Connected = true,
        Disconnect = function(self)
            if not self.Connected then return end

            local handlers = EventBus._handlers[eventName]
            if handlers then
                local index = table.find(handlers, handler)
                if index then
                    table.remove(handlers, index)
                end
            end

            self.Connected = false
        end
    }

    return connection
end

function EventBus:Clear(eventName)
    self._handlers[eventName] = nil
end

return EventBus
