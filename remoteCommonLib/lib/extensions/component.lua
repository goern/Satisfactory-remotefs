-- component class extension functions


require( "/lib/extensions/tables.lua", ____RemoteCommonLib )


---Find and return a table of all the NetworkComponent proxies that are of the given class[es]
---@param class any Class name or table (of tables) of class names
---@return table: indexed table of all NetworkComponents found
function component.getComponentsByClass( class )
    local results = {}
    
    if type( class ) == "table" then
        for _, c in pairs( class ) do
            --print( c )
            table.imerge( results, component.getComponentsByClass( c ) )
        end
        
    elseif type( class ) == "string" then
        --print( class )
        local comps = component.findComponent( findClass( class ) )
        for _, c in pairs( comps ) do
            table.insert( results, component.proxy( c ) )
        end
    end
    
    return results
end


