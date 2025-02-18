---
--- Created by 1000101
--- DateTime: 15/02/2023 7:05 am
---
--- Based on work by Willis
---

local UPDATED = "14/03/2023 1:40 am"
print( "\nInitialising HypertubeNode\n\nLast Update: " .. UPDATED .. "\n" )




--------------------------------------------------------------------------------


HypertubeNode = {
    vertex                  = -1,       -- Unique numeric ID of this Node
    name                    = nil,      -- Human readable display name for a Destination Node
    
    -- Operational Mode of this Node
    MODE_INVALID            = -1,       -- Invalid Node
    MODE_DESTINATION        = 1,        -- Node is in Destination Mode and Configuration
    MODE_JUNCTION           = 2,        -- Node is in Junction Mode and Configuration
    mode                    = -1,       -- Initially
    
    -- The known HypertubeNetwork map
    --[[ key = vertex,
         value = {
            uuid:string = computer uuid,
            vertex:number = Node vertex,
            name:string = Node name (will be nil for pure Junctions),
            mode:number = Node ala Mode,
            map:table = {
                index:number = The index of the RSS Sign Element for this node on the network map display,
                edges:table = Array of indexes for this nodes edges on the network map display,
                iuio:UIOElement = uio for the node on the displays,
                euios:table = Array of uios for this nodes edges on the displays,
            }
        }
    ]]
    nodes                   = {},
    
    map                     = {},
    
    start                   = -1,       -- Current route A
    destination             = -1,       -- Current route B
    route                   = nil,      -- Current route
}
HypertubeNode.__index = HypertubeNode




--------------------------------------------------------------------------------


local ClassGroup = require( "/lib/classgroups.lua", ____RemoteCommonLib )
local RSSBuilder = require( "/lib/RSSBuilder.lua", ____RemoteCommonLib )
local Vector2f = require( "/lib/Vector2f.lua", ____RemoteCommonLib )
local Vector4F = require( "/lib/Vector4F.lua", ____RemoteCommonLib )


local Color = require( "/lib/Colors.lua" )
local UIO = require( "/lib/UIOElements.lua" )
local Network = require( "/lib/Network.lua" )


require( "/lib/AdjacencyMatrix.lua" )


--------------------------------------------------------------------------------


-- All the UI for the Node
HypertubeNode.UIO = {}
HypertubeNode.UIO.__index = HypertubeNode.UIO


HypertubeNode.UIO.ListOpt = {
    startAt = -1,           -- Where the top of the visible window in listData begins
    selected = -1,          -- The currently selected list item
    listData = {},          -- The complete table of data in the list
    listUIOElements = {},   -- The UIOElements available to display the list
    listDn = nil,           -- The "List can be scrolled up" indicator - NOT THE CONTROL ITSELF
    listUp = nil,           -- The "List can be scrolled down" indicator - NOT THE CONTROL ITSELF
    scrollUp = nil,         -- The select previous list item button (scrolls the visible window up when selected is less than startAt)
    scrollDn = nil,         -- The select next list item button (scrolls the visible window down when selected is greater than startAt + #listUIOElements )
}
HypertubeNode.UIO.ListOpt.__index = HypertubeNode.UIO.ListOpt
local listOpt = HypertubeNode.UIO.ListOpt




--------------------------------------------------------------------------------

local PI = 3.1415926535897932384626433832795
local RAD_TO_DEG = 180.0 / PI
local DEG_TO_RAD = PI / 180.0

---Round a number
---@param a number
local function round( a )
    return math.floor( a + 0.5 )
end

---Average two numbers
---@param a number
---@param b number
---@return number
local function average( a, b )
    return a + ( ( b - a ) * 0.5 )
end


---Calculate the centre point, length and, element rotation for the edges RSS sign element
---@param p0 Vector
---@param p1 Vector
---@return Vector, number, number
local function computeEdge( p0, p1 )
    local dX = p0[ 1 ] - p1[ 1 ]
    local dY = p1[ 2 ] - p0[ 2 ]    -- Invert for the sign coord system
    local pX = average( p0[ 1 ], p1[ 1 ] )
    local pY = average( p0[ 2 ], p1[ 2 ] )
    local aR = math.atan2( dX, dY )
    local l = math.sqrt( dX * dX + dY * dY )
    return { pX, pY }, l, ( aR * RAD_TO_DEG )
end


-- Creates the map table key for an edge from the two vertexes ordered as lower:higher
-- eg: (2,7) -> "2:7", (5,3) -> "3:5", etc
---@param v1 number
---@param v2 number
---@return string
local function getMapEdgeKey( v1, v2 )
    if v2 < v1 then
        local v3 = v2
        v2 = v1
        v1 = v3
    end
    return string.format( "%d:%d", v1, v2 )
end


---Set the Z index of the same element on all signs in the array
---@param signs table table {_,sign}
---@param eid number element index
---@param zIndex number zIndex
---@param offset number optional: offset to apply to zIndex, lazy way of doing zIndex + offset at the call site
local function rssElementSetZIndex( signs, eid, zIndex, offset )
    offset = offset or 0
    for _, sign in pairs( signs ) do
        if eid < sign:GetNumOfElements() then
            sign:Element_SetZIndex( zIndex + offset, eid )
        end
    end
end


---Set the same color of the same element on all signs in the array
---@param signs table table {_,sign}
---@param eid number element index
---@param color Color color
local function rssElementSetColor( signs, eid, color )
    for _, sign in pairs( signs ) do
        if eid < sign:GetNumOfElements() then
            sign:Element_SetColor( color, eid )
        end
    end
end




--------------------------------------------------------------------------------
local mapGenerated = false
local signMapValid = false
local exportedTemplate = false

-- How to order the "status" element[s] on the RSS sign[s]
local RSS_STATUS_ZINDEX_STATUS_FRONT            =  64       -- In front of everything
local RSS_STATUS_ZINDEX_STATUS_BACK             = -64       -- Behind the blackground

local RSS_STATUS_ZINDEX_LOCATION                =  40       -- In front List/Map

local RSS_STATUS_ZINDEX_LIST_FRONT              =  32       -- In front of except the status
local RSS_STATUS_ZINDEX_LIST_BACK               = -64       -- Behind the blackground

local RSS_STATUS_ZINDEX_UIO                     =  12       -- In front of filler
local RSS_STATUS_ZINDEX_FILLER                  =   8       -- In front of something

local RSS_STATUS_ZINDEX_HIDDEN                  = -64       -- Behind everything


local ____nextRSSElementIndex                   = 0         -- Don't trust my own ability to track these, do it automagically
local function nextRSSIndex( extra )
    if extra == nil or type( extra ) ~= "number" or extra < 0 then
        extra = 0
    end
    local result = ____nextRSSElementIndex
    ____nextRSSElementIndex = ____nextRSSElementIndex + 1 + extra
    return result
end

-- Where on the RSS sign[s] to find the element[s]
local RSS_EID_STATUS_TEXT                       = nextRSSIndex( 2 ) -- Text + 2

local RSS_EID_LOC_START                         = nextRSSIndex( 2 ) -- Text + 2
local RSS_EID_LOC_DEST                          = nextRSSIndex( 2 ) -- Text + 2
local RSS_EID_LOC_TO                            = nextRSSIndex( 0 ) -- Text

local RSS_EID_LIST_BACKGROUND                   = nextRSSIndex( 0 ) -- Image

local RSS_EID_LIST_INDICATOR_UP                 = nextRSSIndex( 0 ) -- Image
local RSS_EID_LIST_INDICATOR_DN                 = nextRSSIndex( 0 ) -- Image

local RSS_EID_MAP_TOGGLE                        = nextRSSIndex( 1 ) -- Image + 1

local RSS_EID_LIST_SELECT_UP                    = nextRSSIndex( 1 ) -- Image + 1
local RSS_EID_LIST_SELECT_DN                    = nextRSSIndex( 1 ) -- Image + 1

local RSS_EID_ROUTE_COMPUTE                     = nextRSSIndex( 1 ) -- Image + 1

local RSS_EID_ROUTE_RESET                       = nextRSSIndex( 1 ) -- Image + 1

local RSS_EID_FILLER                            = nextRSSIndex( 3 ) -- Image + 3 -- Dogo, Logos

local RSS_EID_BLACKGROUND                       = nextRSSIndex( 0 ) -- Image

local RSS_LIST_COUNT                            = 15
local RSS_EID_LIST_FIRST                        = nextRSSIndex( RSS_LIST_COUNT ) -- Text
local RSS_EID_LIST_LAST                         = RSS_EID_LIST_FIRST + RSS_LIST_COUNT -- Text


-- Where on the user control panel[s] to find the button[s]
local SMP_MI_MAP_TOGGLE                         = { 0, 4 }
local SMP_MI_SELECT_UP                          = { 0, 3 }
local SMP_MI_SELECT_DN                          = { 0, 2 }
local SMP_MI_ROUTE_COMPUTE                      = { 0, 1 }
local SMP_MI_ROUTE_RESET                        = { 0, 0 }

-- Where on the admin control panel[s] to find the button[s]
local FMP_MI_NETWORK_RESET                      = { 0, 0 }


---Generate the sign import string from the sign data table
---@param layout SignLayout SignLayout
---@return string import string that can be pasted into the RSS Sign of the appropriate type.  If ____Disk_UUID is set (and mounted as root) then the import string will be saved to "/rssimport.txt"
local function generateRSSSignImport( layout, filename )
    
    
    local result, import = layout:generateImportEx( "Normal", "2x1" )
    if not result then
        print( "Unable to build import\n\t" .. import )
    end
    
    if ____Disk_UUID ~= nil and ____Disk_UUID ~= '' then
        local writeMap = HypertubeNode.mapHash ~= nil and HypertubeNode.mapHash ~= ''
        local n = "rssimport.txt"
        if not writeMap then
            n = "rssimport_nomap.txt"
        end
        print( 'Saving RSS Sign Import String to "%LocalAppData%\\FactoryGame\\Saved\\SaveGames\\computers\\' .. ____Disk_UUID .. '\\' .. filename ..  '"' )
        local handle = filesystem.open( '/' .. filename, "w" )
        if handle ~= nil then
            if writeMap then
                handle:write( string.format( 'mapHash="%s"\n', HypertubeNode.mapHash ) )
                exportedTemplate = true
            end
            handle:write( import )
            handle:close()
        end
    end
    
    return import
end


---Tests whether a network node is valid.
---@param node table The node to test
---@return boolean, string true/false and reason on failure
local function isNodeValid( node )
    if node == nil then                         -- Dangling pointer
        return false, "node == nil"
    end
    if node.vertex == nil then                  -- Dangling pointer
        return false, string.format( "node.vertex == nil : vertex = %d : uuid = %s", node.vertex, node.uuid )
    end
    if node.vertex > HypertubeNode.hyper_network.size then -- AdjacencyMatrix size mismatch
        return false, string.format( "node.vertex > HypertubeNode.hyper_network.size : vertex = %d : uuid = %s", node.vertex, node.uuid )
    end
    if node.uuid == nil then                    -- Unidentified node - what computer registered this???
        return false, string.format( "node.uuid == nil : vertex = %d", node.vertex )
    end
    if node.location == nil then                -- Dangling pointer
        return false, string.format( "node.location == nil : vertex = %d : uuid = %s", node.vertex, node.uuid )
    end
    return true, nil                            -- Node is valid
end


---Tests whether the network map is complete.  The network map portion of the RSS sign import string cannot be generated until the map is complete.
---@return boolean, string true/false and reason on failure
local function isNetworkMapValid()
    if HypertubeNode.hyper_network == nil then  -- Incomplete network
        return false, "hyper_network == nil"
    end
    local nodes = HypertubeNode.nodes
    local nCount = table.countKeyValuePairs( nodes )
    if nodes == nil or nCount == 0 or nCount < HypertubeNode.vertex then                        -- Incomplete network
        return false, "nodes == nil"
    end
    for _, node in pairs( nodes ) do
        local success, reason = isNodeValid( node )
        if not success then
            return false, reason
        end
        for _, remote in pairs( node.connections ) do
            local r = nodes[ remote ]
            success, reason = isNodeValid( r )
            if not success then
                return false, reason
            end
        end
    end
    return true, nil                            -- No dangling pointers or incomplete network
end


local function addRSSTextElementToLayout( layout, eIndex, mElementName, mZIndex, mPosition, mText, mTextSize, mTextJustify, mColourOverwrite, mPadding )
    local mSharedData = RSSBuilder.SignLayout.ElementData.SharedData.new( {
        mElementName = mElementName,
        mPosition = mPosition,
        mZIndex = mZIndex,
        mColourOverwrite = mColourOverwrite,
    } )
    if mSharedData == nil then computer.stop() end
    local mTextData = RSSBuilder.SignLayout.ElementData.TextData.new( {
        mText = mText,
        mTextSize = mTextSize,
        mTextJustify = mTextJustify,
        mPadding = mPadding,
    } )
    if mTextData == nil then computer.stop() end
    if not layout:addElement( RSSBuilder.SignLayout.ElementData.new( {
        eIndex = eIndex,
        mElementType = "Text",
        mSharedData = mSharedData,
        mTextData = mTextData,
    } ) ) then computer.stop() end
end


local function addRSSImageElementToLayout( layout, eIndex, mElementName, mZIndex, mPosition, mTexture, mColourOverwrite, mOverwriteImageSize, mUse9SliceMode, mUrl, mImageSize, mRotation )
    local mIsUsingCustom = ( mUrl ~= nil )and( type( mUrl ) == "string" )and( mUrl ~= '' )
    if mIsUsingCustom == false then mIsUsingCustom = nil end
    local mSharedData = RSSBuilder.SignLayout.ElementData.SharedData.new( {
        mElementName = mElementName,
        mPosition = mPosition,
        mZIndex = mZIndex,
        mTexture = mTexture,
        mColourOverwrite = mColourOverwrite,
        mUrl = mUrl,
        mIsUsingCustom = mIsUsingCustom,
        mRotation = mRotation,
    } )
    if mSharedData == nil then computer.stop() end
    local mImageData = RSSBuilder.SignLayout.ElementData.ImageData.new(
        {
            mImageSize = mImageSize,
            mOverwriteImageSize = mOverwriteImageSize,
            mUse9SliceMode = mUse9SliceMode,
        } )
    if mImageData == nil then computer.stop() end
    if not layout:addElement( RSSBuilder.SignLayout.ElementData.new( {
        eIndex = eIndex,
        mElementType = "Image",
        mSharedData = mSharedData,
        mImageData = mImageData,
    } ) ) then computer.stop() end
end


---Create the core RSS Sign data and elements
---@return table
local function generateRSSSignBaseData()
    local layout = RSSBuilder.SignLayout.new(
        {
            signSize = "2x1"
        } )
    if layout == nil then
        computer.panic( "Oh shiz!\n" .. debug.traceback() )
        return nil
    end
    
    
    -- Status
    local mPosition = Vector2f.new( 0.000000, 200.000000 )
    local mOverwriteImageSize = Vector2f.new( 768.000000, 96.000000 )
    local bdrTexture = "/RSS/Assets/Images/UI/Shapes/7x1/build_7x1_holo.build_7x1_holo"
    local bdrUse9SliceModeStatus = Vector2f.new( 1.000000, 0.010000 )
    local bgdTexture = "/KUI/Assets/9Slice/9S1111.9S1111"
    local bgdUse9SliceModeStatus = Vector2f.new( 1.000000, 0.250000 )
    addRSSTextElementToLayout ( layout, RSS_EID_STATUS_TEXT     , "txtStatus", RSS_STATUS_ZINDEX_STATUS_FRONT    , mPosition, "Status of this node", 15, RSSBuilder.Text.Justification.Middle )
    addRSSImageElementToLayout( layout, RSS_EID_STATUS_TEXT +  1, "bdrStatus", RSS_STATUS_ZINDEX_STATUS_FRONT - 1, mPosition, bdrTexture, Color.GREY_0750    , mOverwriteImageSize, bdrUse9SliceModeStatus )
    addRSSImageElementToLayout( layout, RSS_EID_STATUS_TEXT +  2, "bgdStatus", RSS_STATUS_ZINDEX_STATUS_FRONT - 2, mPosition, bgdTexture, Color.CYAN_SIGN_LOW, mOverwriteImageSize, bgdUse9SliceModeStatus )
    
    
    -- Current Location
    mPosition = Vector2f.new( 320.000000, -200.000000 )
    mOverwriteImageSize = Vector2f.new( 360.000000, 96.000000 )
    addRSSTextElementToLayout ( layout, RSS_EID_LOC_START     , "txtLocCurr", RSS_STATUS_ZINDEX_LOCATION    , mPosition, "Current Location", 15, RSSBuilder.Text.Justification.Middle )
    addRSSImageElementToLayout( layout, RSS_EID_LOC_START +  1, "bdrLocCurr", RSS_STATUS_ZINDEX_LOCATION - 1, mPosition, bdrTexture, Color.GREY_0750    , mOverwriteImageSize )
    addRSSImageElementToLayout( layout, RSS_EID_LOC_START +  2, "bgdLocCurr", RSS_STATUS_ZINDEX_LOCATION - 2, mPosition, bgdTexture, Color.BLUE_SIGN_LOW, mOverwriteImageSize )
    
    
    -- Destination Location
    mPosition = Vector2f.new( 320.000000, -20.000000 )
    addRSSTextElementToLayout ( layout, RSS_EID_LOC_DEST     , "txtLocDest", RSS_STATUS_ZINDEX_LOCATION    , mPosition, "Destination Location", 15, RSSBuilder.Text.Justification.Middle )
    addRSSImageElementToLayout( layout, RSS_EID_LOC_DEST +  1, "bdrLocDest", RSS_STATUS_ZINDEX_LOCATION - 1, mPosition, bdrTexture, Color.GREY_0750     , mOverwriteImageSize )
    addRSSImageElementToLayout( layout, RSS_EID_LOC_DEST +  2, "bgdLocDest", RSS_STATUS_ZINDEX_LOCATION - 2, mPosition, bgdTexture, Color.GREEN_SIGN_LOW, mOverwriteImageSize )
    
    
    -- Location Preposition
    mPosition = Vector2f.new( 320.000000, -110.000000 )
    addRSSTextElementToLayout ( layout, RSS_EID_LOC_TO     , "txtCurrToDest", RSS_STATUS_ZINDEX_LOCATION, mPosition, "To", 25, RSSBuilder.Text.Justification.Middle )
    
    
    -- List/Map Area
    
    -- Border
    mPosition = Vector2f.new( -192.000000, 0.000000 )
    mOverwriteImageSize = Vector2f.new( 640.000000, 512.000000 )
    local mTexture = "/RSS/Assets/Images/UI/Shapes/1x2/1x2_outline1.1x2_outline1"
    local mUse9SliceMode = Vector2f.new( 1.000000, 0.067500 )
    addRSSImageElementToLayout( layout, RSS_EID_LIST_BACKGROUND, "bdrListMapArea", RSS_STATUS_ZINDEX_FILLER, mPosition, mTexture, Color.ORANGE_SIGN_HIGH, mOverwriteImageSize, mUse9SliceMode )
    
    -- List Up Icon
    mPosition = Vector2f.new( 74.000000, -202.000000 )
    mOverwriteImageSize = Vector2f.new( 48.000000, 48.000000 )
    mTexture = "/RSS/Assets/Images/1x1/1x1_arrow_up.1x1_arrow_up"
    local mColourOverwrite = Color.new( 0.095307, 0.095307, 0.095307, 1.000000 )
    addRSSImageElementToLayout( layout, RSS_EID_LIST_INDICATOR_UP, "icnListMoreUp", RSS_STATUS_ZINDEX_LIST_FRONT, mPosition, mTexture, mColourOverwrite, mOverwriteImageSize )
    
    -- List Down Icon
    mPosition = Vector2f.new( 74.000000, 175.000000 )
    mTexture = "/RSS/Assets/Images/1x1/1x1_arrow_down.1x1_arrow_down"
    addRSSImageElementToLayout( layout, RSS_EID_LIST_INDICATOR_DN, "icnListMoreDn", RSS_STATUS_ZINDEX_LIST_FRONT, mPosition, mTexture, mColourOverwrite, mOverwriteImageSize )
    
    
    -- UIO - List / Map Toggle
    mOverwriteImageSize = Vector2f.new( 24.000000, 24.000000 )
    mTexture = "/Game/FactoryGame/Buildable/Factory/DroneStation/UI/TXUI_Drone_Input.TXUI_Drone_Input"
    mPosition = Vector2f.new( 496.000000, 57.000000 )
    addRSSImageElementToLayout( layout, RSS_EID_MAP_TOGGLE    , "icnMapToggle", RSS_STATUS_ZINDEX_UIO    , mPosition, mTexture, Color.CYAN_SIGN_LOW, mOverwriteImageSize )
    local mPadding = Vector4F.new( 10.000000, 5.000000, 10.000000, 5.000000 )
    mPosition = Vector2f.new( 488.000000, 57.000000 )
    addRSSTextElementToLayout ( layout, RSS_EID_MAP_TOGGLE + 1, "txtMapToggle", RSS_STATUS_ZINDEX_UIO + 1, mPosition, "Display Map", 12, RSSBuilder.Text.Justification.Right, nil, mPadding )
    
    -- UIO - Select Up
    mPosition = Vector2f.new( 496.000000, 81.000000 )
    addRSSImageElementToLayout( layout, RSS_EID_LIST_SELECT_UP    , "icnSelectUp", RSS_STATUS_ZINDEX_UIO    , mPosition, mTexture, Color.ORANGE_SIGN_LOW, mOverwriteImageSize )
    mPosition = Vector2f.new( 488.000000, 81.000000 )
    addRSSTextElementToLayout ( layout, RSS_EID_LIST_SELECT_UP + 1, "txtSelectUp", RSS_STATUS_ZINDEX_UIO + 1, mPosition, "Scroll Up", 12, RSSBuilder.Text.Justification.Right, nil, mPadding )
    
    -- UIO - Select Down
    mPosition = Vector2f.new( 496.000000, 105.000000 )
    addRSSImageElementToLayout( layout, RSS_EID_LIST_SELECT_DN    , "icnSelectDn", RSS_STATUS_ZINDEX_UIO    , mPosition, mTexture, Color.ORANGE_SIGN_LOW, mOverwriteImageSize )
    mPosition = Vector2f.new( 488.000000, 105.000000 )
    addRSSTextElementToLayout ( layout, RSS_EID_LIST_SELECT_DN + 1, "txtSelectDn", RSS_STATUS_ZINDEX_UIO + 1, mPosition, "Scroll Down", 12, RSSBuilder.Text.Justification.Right, nil, mPadding )
    
    -- UIO - Compute Route / Quick Return
    mPosition = Vector2f.new( 496.000000, 129.000000 )
    addRSSImageElementToLayout( layout, RSS_EID_ROUTE_COMPUTE    , "icnComputeRoute", RSS_STATUS_ZINDEX_UIO    , mPosition, mTexture, Color.GREEN_SIGN_LOW, mOverwriteImageSize )
    mPosition = Vector2f.new( 488.000000, 129.000000 )
    addRSSTextElementToLayout ( layout, RSS_EID_ROUTE_COMPUTE + 1, "txtComputeRoute", RSS_STATUS_ZINDEX_UIO + 1, mPosition, "Compute Route", 12, RSSBuilder.Text.Justification.Right, nil, mPadding )
    
    -- UIO - Reset Routing
    mPosition = Vector2f.new( 496.000000, 153.000000 )
    addRSSImageElementToLayout( layout, RSS_EID_ROUTE_RESET    , "icnResetRouting", RSS_STATUS_ZINDEX_UIO    , mPosition, mTexture, Color.RED_SIGN_LOW, mOverwriteImageSize )
    mPosition = Vector2f.new( 488.000000, 153.000000 )
    addRSSTextElementToLayout ( layout, RSS_EID_ROUTE_RESET + 1, "txtResetRouting", RSS_STATUS_ZINDEX_UIO + 1, mPosition, "Reset Routing", 12, RSSBuilder.Text.Justification.Right, nil, mPadding )
    
    
    -- Some filler
    
    -- Doggo
    mOverwriteImageSize = Vector2f.new( 96.000000, 192.000000 )
    mTexture = "/RSS/Assets/Images/1x2/1x2_difd.1x2_difd"
    mPosition = Vector2f.new( 234.000000, 148.000000 )
    addRSSImageElementToLayout( layout, RSS_EID_FILLER    , "icnLogoDoggo", RSS_STATUS_ZINDEX_FILLER, mPosition, mTexture, nil, mOverwriteImageSize )
    
    -- 1000101
    mOverwriteImageSize = Vector2f.new( 48.000000, 48.000000 )
    mTexture = "/RSS/Assets/Images/Milestones/rss_milestone.rss_milestone"
    local mUrl = "http://localhost/remotefs/HypertubeNetwork/images/ANS-E-Profile.png"
    mPosition = Vector2f.new( 352.000000, 224.000000 )
    addRSSImageElementToLayout( layout, RSS_EID_FILLER + 1, "icnLogoMe"   , RSS_STATUS_ZINDEX_FILLER, mPosition, mTexture, nil, mOverwriteImageSize, nil, mUrl )
    
    -- FIN
    mUrl = "http://localhost/remotefs/HypertubeNetwork/images/ficsit-network-logo.png"
    mPosition = Vector2f.new( 416.000000, 224.000000 )
    addRSSImageElementToLayout( layout, RSS_EID_FILLER + 2, "icnLogoFIN"  , RSS_STATUS_ZINDEX_FILLER, mPosition, mTexture, nil, mOverwriteImageSize, nil, mUrl )
    
    -- RSS2
    mTexture = "/KUI/Assets/Logo/TXUI_Logo_RSS.TXUI_Logo_RSS"
    mPosition = Vector2f.new( 480.000000, 224.000000 )
    addRSSImageElementToLayout( layout, RSS_EID_FILLER + 3, "icnLogoRSS2" , RSS_STATUS_ZINDEX_FILLER, mPosition, mTexture, nil, mOverwriteImageSize )
    
    -- And the blackground to hide elements behind
    mTexture = "/RSS/Assets/Images/UI/Shapes/Custom/shape_square.shape_square"
    local mImageSize = Vector2f.new( 1.000000, 1.000000 )
    addRSSImageElementToLayout( layout, RSS_EID_BLACKGROUND, "imgBlackground" , 0, nil, mTexture, Color.BLACK, nil, nil, nil, mImageSize )
    
    -- Add the List Option Entries
    local oIndex = 0
    local yOpt = -205.000000
    for eIndex = RSS_EID_LIST_FIRST, RSS_EID_LIST_LAST do
        local mTextID = "txtListOpt" .. tostring( oIndex )
        mPosition = Vector2f.new( -192.000000, yOpt )
        addRSSTextElementToLayout ( layout, eIndex, mTextID, RSS_STATUS_ZINDEX_LIST_FRONT, mPosition, '', 15, RSSBuilder.Text.Justification.Middle, nil, mPadding )
        oIndex = oIndex + 1
        yOpt = yOpt + 25.0
    end
    
    
    return layout
end


---Append the Network Map RSS Sign data as well as generate the HypertubeNode.map
---@param layout SIgnLayout The core sign data and elements
---@return boolean true/false if the map elements were added to the layout.elements
local function appendRSSSignMapData( layout )
    -- Make sure the entire map is loaded
    HypertubeNode.mapHash = nil
    local networkValid, reason = isNetworkMapValid()
    if not networkValid then
        print( reason )
        return false
    end
    
    
    -- Setup the limits of the render window for the map
    local mapWindow = { -478, -222, 96, 196 }
    local mapX = mapWindow[ 3 ] - mapWindow[ 1 ]
    local mapY = mapWindow[ 4 ] - mapWindow[ 2 ]
    local minNodeX =  1000000.0
    local minNodeY =  1000000.0
    local maxNodeX = -1000000.0
    local maxNodeY = -1000000.0
    
    -- Get the physical size limits of the network so we can place everything in the window
    local nodes = HypertubeNode.nodes
    for _, node in pairs( nodes ) do
        local loc = node.location
        if loc.x < minNodeX then minNodeX = loc.x end
        if loc.x > maxNodeX then maxNodeX = loc.x end
        if loc.y < minNodeY then minNodeY = loc.y end
        if loc.y > maxNodeY then maxNodeY = loc.y end
    end
    
    -- Determine the scale to use
    local scaleX = mapX / ( maxNodeX - minNodeX )
    local scaleY = mapY / ( maxNodeY - minNodeY )
    local scale = scaleX
    if scaleY < scaleX then scale = scaleY end
    
    --print( scaleX, scaleY, mapX, mapY, mapWindow[ 1 ], mapWindow[ 2 ], mapWindow[ 3 ], mapWindow[ 4 ] )
    
    -- Recentre the window on the smaller axis
    if scaleX < scaleY then
        -- Scale Y to X
        local mScale = scaleX / scaleY
        local newY = round( mapY * mScale * 0.5 )
        local cY = average( mapWindow[ 2 ], mapWindow[ 4 ] )
        mapWindow[ 2 ] = cY - newY
        mapWindow[ 4 ] = cY + newY
    elseif scaleY < scaleX then
        -- Scale X to Y
        local mScale = scaleY / scaleX
        local newX = round( mapX * mScale * 0.5 )
        local cX = average( mapWindow[ 1 ], mapWindow[ 3 ] )
        mapWindow[ 1 ] = cX - newX
        mapWindow[ 3 ] = cX + newX
    end
    
    --print( scaleX, scaleY, mapX, mapY, mapWindow[ 1 ], mapWindow[ 2 ], mapWindow[ 3 ], mapWindow[ 4 ] )
    
    -- Add the map elements after the blackground so they are initially hidden
    -- and the major components of the sign maintain their static indexes
    local eID = nextRSSIndex() -- This will be the last call to it, don't care about the number of elements we are actually adding
    local map = {}
    local mapHash = 0
    
    local function addToHash( value, rotate )
        if value == nil or type( value ) ~= "number" then
            computer.panic( "appendRSSSignMapData().addToHash() - value must be a number" )
        end
        if value == 0 then return end
        rotate = rotate or 0
        rotate = rotate % 32
        
        if rotate < 0 then
            rotate = -rotate
            local ror = value << ( 32 - rotate )
            local shr = value >> rotate
            value = ror | shr
        elseif rotate > 0 then
            local rol = value >> ( 32 - rotate )
            local shl = value << rotate
            value = rol | shl
        end
        
        mapHash = mapHash ~ value
    end
    
    local mOverwriteImageSizeNode = Vector2f.new( 12.000000, 12.000000 )
    local mTextureDestination = "/RSS/Assets/Images/UI/Shapes/Custom/shape_circle.shape_circle"
    local mTextureJunction = "/RSS/Assets/Images/UI/Shapes/Custom/shape_diamond.shape_diamond"
    local mTextureEdge = "/RSS/Assets/Images/UI/Shapes/Custom/shape_square.shape_square"
    
    -- Create elements for the nodes first
    for i = 1, HypertubeNode.hyper_network.size do
        local node = nodes[ i ]
        --print( i, node )
        
        if node ~= nil then
            local mTexture = ''
            local zOff = 0
            if node.mode == HypertubeNode.MODE_DESTINATION then
                mTexture = mTextureDestination
            elseif node.mode == HypertubeNode.MODE_JUNCTION then
                zOff = -1   -- Put junctions behind destinations on the display
                mTexture = mTextureJunction
            else
                computer.panic( "generateRSSSignTemplateData() - Node is invalid\n\tuuid  : " .. node.uuid .. "\n\tvertex: " .. tostring( node.vertex ) )
            end
            
            local pX = mapWindow[ 1 ] + ( node.location.x - minNodeX ) * scale
            local pY = mapWindow[ 2 ] + ( node.location.y - minNodeY ) * scale
            
            local mPosition = Vector2f.new( pX, pY )
            addRSSImageElementToLayout( layout, eID, "node:" .. tostring( node.vertex ), RSS_STATUS_ZINDEX_LIST_BACK - 1, mPosition, mTexture, Color.GREY_0125, mOverwriteImageSizeNode )
            
            -- Map the vertex index to the map element index
            map[ node.vertex ] = { element = eID, zOffset = zOff }
            
            addToHash( node.vertex, eID )
            
            eID = eID + 1
        end
    end
    
    -- Now go through all the connections, adding each unique edge
    -- edge 1->2 is the same as 2->1 for display purposes
    for i = 1, HypertubeNode.hyper_network.size do
        local node = nodes[ i ]
        --print( i, node )
        
        if node ~= nil then
            
            -- Sort the connections so the elements are created in the exact same order as long
            -- as the network topology itself doesn't change - that is, no nodes or connections
            -- are added, removed or, changed.  Changing the network topology requires updating
            -- the signs at all destination nodes.
            table.sort( node.connections ) --, function( a, b ) return a < b end )
            
            local numconn = table.countKeyValuePairs( node.connections )
            
            local zOff = -2
            for j = 1, numconn do
                local remote = node.connections[ j ]
                --print( "\t", j, remote )
                
                local edge = getMapEdgeKey( node.vertex, remote )
                if map[ edge ] == nil then
                    
                    --print( node.vertex, remote, edge )
                    
                    local nl = node.location
                    local rl = nodes[ remote ].location
                    
                    local eP, eL, eA = computeEdge( { nl.x, nl.y }, { rl.x, rl.y } )
                    eP[ 1 ] = mapWindow[ 1 ] + ( eP[ 1 ] - minNodeX ) * scale
                    eP[ 2 ] = mapWindow[ 2 ] + ( eP[ 2 ] - minNodeY ) * scale
                    eL = eL * scale
                    
                    local mPosition = Vector2f.new( eP[ 1 ], eP[ 2 ] )
                    local mOverwriteImageSize = Vector2f.new( 1.500000, eL )
                    addRSSImageElementToLayout( layout, eID, "edge:" .. edge, RSS_STATUS_ZINDEX_LIST_BACK - 2, mPosition, mTextureEdge, Color.GREY_0125, mOverwriteImageSize, nil, nil, nil, eA )
                    
                    -- Map the edge to the map element index with the edges behind both the destination and junction nodes
                    map[ edge ] = { element = eID, zOffset = zOff }
                    
                    addToHash( node.vertex, eID + zOff * j )
                    addToHash( remote, eID - zOff * j )
                    
                    eID = eID + 1
                end
            end
        end
    end
    
    HypertubeNode.map = map
    HypertubeNode.mapHash = string.format( "%x8", mapHash )
    
    print( "mapHash: " .. HypertubeNode.mapHash )
    
    return true
end




--------------------------------------------------------------------------------

function HypertubeNode.getModeName( mode )
    if mode == HypertubeNode.MODE_DESTINATION then
        return "MODE_DESTINATION"
    elseif mode == HypertubeNode.MODE_JUNCTION then
        return "MODE_JUNCTION"
    end
    return "MODE_INVALID"
end



---Read the node "name" value from the computer settings
---@return boolean: HypertubeNode.mode == HypertubeNode.MODE_DESTINATION
local function getNodeName()
    local name = ____ComputerSettings[ "name" ]             -- Only for destinations
    if name ~= nil and name == '' then name = nil end       -- Force empty to nil
    HypertubeNode.name = name                               -- Assign the name
    if name ~= nil then
        HypertubeNode.mode = HypertubeNode.MODE_DESTINATION
        print( "name: " .. HypertubeNode.name )
    else
        HypertubeNode.mode = HypertubeNode.MODE_JUNCTION
    end
end


---Read the node "vertex" value from the computer settings
local function getNodeVertex()
    local vertex = ____ComputerSettings[ "vertex" ]
    if vertex == nil or tonumber( vertex ) == nil then
        computer.panic( "Invalid vertex" )
    end
    HypertubeNode.vertex = tonumber( vertex )
    print( "vertex: " .. tostring( HypertubeNode.vertex ) )
end



---Find the NetworkRouter in the Component Network and make sure it has an easily identifiable name on both sides
local function getNodeRouter()
    -- Find the router and name the WAN side so that this node can be identified on the WAN
    local routers = component.getComponentsByClass( ClassGroup.Networking.Routers.All )
    if routers == nil then
        computer.panic( "Cannot find NetworkRouter - Nodes must be isolated on their own Component Network")
    end
    if #routers == 0 then
        computer.panic( "NetworkRouter Required - Nodes must be isolated on their own Component Network by a SINGLE NetworkRouter")
    elseif #routers > 1 then
        computer.panic( "Too many NetworkRouters - Nodes must be isolated on their own Component Network by a SINGLE NetworkRouter")
    end
    -- Name the router LAN and WAN sides
    local router = routers[ 1 ]
    local connectors = router:getNetworkConnectors()
    local n = "HypertubeNode:" .. HypertubeNode.vertex
    connectors[ 1 ].nick = n
    connectors[ 2 ].nick = n
    -- Tell the router only to pass messages through on the HypertubeNetwork port, this will reduce local network traffic for each node
    --router:addPortList( Network.port ) -- Doesn't work???
    --router:setPortList( { Network.port } ) -- Invalid instance - wtf???
    --[[local ports = router:getPortList()
    print( "ports : " .. #ports )
    for _, port in pairs( ports ) do
        print( "\t" .. tostring( port ) )
    end]]
end


---Read the node connections from the switch nicknames on the same component network
local function getNodeConnections()
    -- By reading the switches nicknames we can determine what nodes we connect to
    local switches = component.getComponentsByClass( ClassGroup.CircuitSwitches.All )
    if #switches < 1 then
        computer.panic( "At least one circuit switch is required for a node" )
    end
    
    -- Create a table of remote,true from the switches
    local hasConn = {}
    for _, switch in pairs( switches ) do
        switch.isSwitchOn = false           -- Turn it off
        local nick = switch.nick
        local remote = tonumber( nick )
        if remote ~= nil then
            if hasConn[ remote ] == nil then
                -- Multiple switches with the same remote vertex is okay, just don't add the connection multiple times
                hasConn[ remote ] = true
            end
        elseif nick ~= nil and nick ~= '' then
            computer.panic( "Circuit switch detected with an invalid nickname.  The only switches on the same component network as this computer should be for this HypertubeNode.  The nickname of each switch must corrospond to the remote node they power the tube to.  eg, a switch to vertex 1 should have the nickname of '1' (no quotes).  Any other switches with no nickname set are assumed to be present for network expansion and have not yet been linked." )
        else
            print( "Ignoring switch : " .. switch.internalName )
        end
    end
    
    -- Now convert the remote,true table into _,remote for the connections
    local connCount = table.countKeyValuePairs( hasConn )
    print( "connections: " .. tostring( connCount ) )
    if connCount < 1 then
        computer.panic( "Could not detect any switches with remote vertex IDs as their nicknames to generate the array of connections from" )
    end
    local connections = {}
    for remote, _ in pairs( hasConn ) do
        print( "\t-> " .. tostring( remote ) )
        if remote == HypertubeNode.vertex then
            computer.panic( "Invalid connection, can't go to myself" )
        end
        table.insert( connections, remote )
    end
    
    -- If we're here then we have properly named switches and a "valid" connection array
    HypertubeNode.connections = connections
end


---Get the vertex for a node by the node name
---@param name string Node name
---@return integer: Node vertex or -1 if the node name is not found in the network map
local function getDestinationByName( name )
    if name == nil or name == '' then return -1 end
    for v, node in pairs( HypertubeNode.nodes ) do
        if node.name == name then
            return v
        end
    end
    return -1
end


function HypertubeNode.UIO.ListOpt.getSelectedDestination()
    return getDestinationByName( listOpt.listData[ listOpt.selected ] )
end


function HypertubeNode.UIO.ListOpt.setListData( nodes )
    --print( "HypertubeNode.UIO.ListOpt.setListData()" )
    
    local vertex = HypertubeNode.vertex
    
    local sortedList = {}
    for vert, node in pairs( nodes ) do
        -- Isn't this node and the node has a name
        if vertex ~= node.vertex and node.name ~= nil then
            -- Only add this node to this nodes list of destinations if we can actually path there from here
            local route = HypertubeNode.hyper_network:generate_path( vertex, node.vertex )
            if #route ~= 0 then
                --local s = string.format( '[%d] %s', node.vertex, node.name )
                local s = node.name
                table.insert( sortedList, s )
            end
        end
    end
    
    table.sort( sortedList )
    
    local newLen = #sortedList
    if newLen > 0 then
        if listOpt.startAt  < 1      then listOpt.startAt  = 1      end
        if listOpt.selected < 1      then listOpt.selected = 1      end
        if listOpt.startAt  > newLen then listOpt.startAt  = newLen end
        if listOpt.selected > newLen then listOpt.selected = newLen end
    else
        listOpt.startAt = -1
        listOpt.selected = -1
    end
    
    listOpt.listData = sortedList
    HypertubeNode.destination = getDestinationByName( listOpt.listData[ listOpt.selected ] )
end


function HypertubeNode.UIO.ListOpt.clearElements()
    for _, element in pairs( HypertubeNode.UIO.ListOpt.listUIOElements ) do
        element:setText( '' )
    end
    listOpt.listUp:setState( false )
    listOpt.listDn:setState( false )
    listOpt.scrollUp:setState( false )
    listOpt.scrollDn:setState( false )
end


function HypertubeNode.UIO.ListOpt.updateElements()
    
    local selected = listOpt.selected
    local listData = listOpt.listData
    local start = listOpt.startAt
    local sIndex = start
    local last = #listData
    
    --print( start, last, selected )
    
    for idx = RSS_EID_LIST_FIRST, RSS_EID_LIST_LAST do
        local element = listOpt.listUIOElements[ idx ]
        if sIndex < 1 or sIndex > last then
            element:setText( '' )
        elseif sIndex >= 1 then
            element:setText( listData[ sIndex ] )
            element:setState( sIndex == selected )
            sIndex = sIndex + 1
        end
    end
    
    listOpt.listUp:setState( start > 1 )
    listOpt.listDn:setState( sIndex > 0 and sIndex < last )
    listOpt.scrollUp:setState( selected > 1 )
    listOpt.scrollDn:setState( selected > 0 and selected < last )
    
end




---Create an RSSElement or panic
---@param sign userdata: The RSSSign
---@param index number: The index of the element on the sign
---@param zOffset number?: Optional zOffset to apply when setZIndex is called on the RSSElement
---@return UIO.UIOElements.RSSElement|nil
local function createRSSElement( sign, index, zOffset )
    local uio = UIO.UIOElements.RSSElement.create( sign, index )
    if uio == nil then
        computer.panic( "Unable to create UIO.UIOElements.RSSElement!\n" .. debug.traceback() )
    end
    uio.zOffset = zOffset
    return uio
end


---Create a Button Module or panic
---@param button userdata: The Button
---@return UIO.UIOElements.ButtonModule|nil
local function createButtonModule( button )
    local uio = UIO.UIOElements.ButtonModule.create( button )
    if uio == nil then
        computer.panic( "Unable to create UIO.UIOElements.ButtonModule!\n" .. debug.traceback() )
    end
    return uio
end


---Create the "status" combinator
---@param signs table?: RSSSigns
---@return UIO.UIOElements.Combinator|nil
local function createStatusCombinator( signs )
    local combined = {}
    
    if signs ~= nil then
        for _, sign in pairs( signs ) do
            table.insert( combined, createRSSElement( sign, RSS_EID_STATUS_TEXT    ,  1 ) )
            table.insert( combined, createRSSElement( sign, RSS_EID_STATUS_TEXT + 1,  0 ) )
            table.insert( combined, createRSSElement( sign, RSS_EID_STATUS_TEXT + 2, -1 ) )
        end
    end
    
    local combinator = UIO.UIOElements.Combinator.create( combined )
    
    return combinator
end


---Create a basic RSSElement with optional true/false state colors and control
---@param signs? table: The RSSSigns
---@param index number: The index of the element on the sign
---@param ctrue table?: {r,g,b,a} color table for "true" state
---@param cfalse table?: {r,g,b,a} color table for "false" state
---@return (UIO.UIOElements.Combinator)?
local function createSimpleDisplayCombinator( signs, index, ctrue, cfalse )
    local combined = {}
    local addStateColor = ( ctrue ~= nil )and( cfalse ~= nil )
    
    if signs ~= nil then
        for _, sign in pairs( signs ) do
            local uio = createRSSElement( sign, index,  0 )
            if addStateColor then
                UIO.UIOElement.Extensions.AddBoolStateColours( uio, ctrue, cfalse )
            end
            table.insert( combined, uio )
        end
    end
    
    local combinator = UIO.UIOElements.Combinator.create( combined )
    if addStateColor then
        UIO.UIOElement.Extensions.AddBoolStateControl( combinator )
    end
    
    return combinator
end


local function createUserControlCombinator( signs, panels, iconIndex, buttonPos, iconColorHigh, iconColorLow, buttonColorHigh, buttonColorLow, labelIndex )
    local combined = {}
    local hasIcon = iconIndex ~= nil and type( iconIndex ) == "number"
    local hasLabel = labelIndex ~= nil and type( labelIndex ) == "number"
    local hasButton = buttonPos ~= nil and type( buttonPos ) == "table"
    
    if signs ~= nil then
        for _, sign in pairs( signs ) do
            if hasIcon then
                local uio = createRSSElement( sign, iconIndex,  0 )
                UIO.UIOElement.Extensions.AddBoolStateColours( uio, iconColorHigh, iconColorLow )
                table.insert( combined, uio )
            end
            if hasLabel then
                local uio = createRSSElement( sign, labelIndex,  0 )
                table.insert( combined, uio )
            end
        end
    end
    
    if panels ~= nil then
        for _, panel in pairs( panels ) do
            if hasButton then
                local button = panel:getModule( buttonPos[ 1 ], buttonPos[ 2 ] )
                if button == nil then
                    computer.panic( "Module Panel is missing button at { " .. tostring( buttonPos[ 1 ] ).. ", " .. tostring( buttonPos[ 2 ] ) .. " }!\n\tPanel : " .. panel.id .. "\n" .. debug.traceback() )
                end
                local uio = createButtonModule( button )
                UIO.UIOElement.Extensions.AddBoolStateColours( uio, buttonColorHigh, buttonColorLow )
                table.insert( combined, uio )
            end
        end
    end
    
    --print( tostring( #combined ) .. " UIOElements to be combined!\n" .. debug.traceback() )
    
    local combinator = UIO.UIOElements.Combinator.create( combined )
    UIO.UIOElement.Extensions.AddBoolStateControl( combinator )
    UIO.UIOElement.Extensions.AddSignalBlockControl( combinator )
    
    return combinator
end




---Create the array of RSSElements to use for the options list data
local function createListOptUIOElements( signs )
    for idx = RSS_EID_LIST_FIRST, RSS_EID_LIST_LAST do
        listOpt.listUIOElements[ idx ] = createSimpleDisplayCombinator( signs, idx, Color.WHITE, Color.GREY_0125 )
    end
end




local function calculateNetworkTimeoutTimestamp()
    return computer.millis() + HypertubeNode.hyper_network.size * Network.Default.TIMEOUT_PER_NODE
end




---Changes the mode of the "Compute Route" button from "normal" A->B to "quick return" B->A of a programmed route
---@param aToB boolean: (true) Normal mode, (false) reverse route mode
function HypertubeNode.changeComputeRouteMode( aToB )
    if HypertubeNode.mode ~= HypertubeNode.MODE_DESTINATION then return end
    if aToB == nil or type( aToB ) ~= "boolean" then
        aToB = true
    end
    HypertubeNode.UIO.ComputeRoute.aToB = aToB
    if aToB then
        HypertubeNode.UIO.ComputeRoute:setText( "Compute Route" )
    else
        HypertubeNode.UIO.ComputeRoute:setText( "Quick Return" )
    end
end



local function checkRSSSignElementHashes()
    if HypertubeNode.mode ~= HypertubeNode.MODE_DESTINATION then return false end
    if HypertubeNode.signs == nil or #HypertubeNode.signs == 0 then return false end
    local mapHash = HypertubeNode.mapHash
    if mapHash == nil then return false end
    
    for _, sign in pairs( HypertubeNode.signs ) do
        
        local signSettings = readNetworkComponentSettings( sign )
        if signSettings == nil then return false end
        
        local signMapHash = signSettings[ "mapHash" ]
        if signMapHash == nil then return false end
        if signMapHash ~= mapHash then return false end
        
        print( "signMapHash = " .. signMapHash )
        
    end
    
    return true
end


function HypertubeNode.updateMapToggleMode( showMap )
    if HypertubeNode.mode ~= HypertubeNode.MODE_DESTINATION then return end
    if showMap == nil then showMap = HypertubeNode.UIO.MapToggle.showMap end
    if showMap == nil then showMap = false end
    local uioState = showMap
    
    local networkValid, reason = isNetworkMapValid()
    --print( networkValid, reason )
    
    if not signMapValid then
        if networkValid then
            local layout = generateRSSSignBaseData()
            mapGenerated = appendRSSSignMapData( layout )
            if mapGenerated then
                generateRSSSignImport( layout, "rssimport_" .. layout.signSize ..  "_map.txt" )
                signMapValid = mapGenerated and checkRSSSignElementHashes()
                if signMapValid then
                    for _, sign in pairs( HypertubeNode.signs ) do
                        -- Enforce the layout of the main elements
                        layout:apply( sign )
                        -- Quickly hide extra elements behind the blackground
                        for eid = RSS_EID_BLACKGROUND + 1, sign:GetNumOfElements() - 1 do
                            sign:Element_SetZIndex( RSS_STATUS_ZINDEX_HIDDEN, eid )
                        end
                    end
                    HypertubeNode.UIO.NodeStatus:setZIndex( RSS_STATUS_ZINDEX_STATUS_BACK )
                end
            end
        end
        showMap = showMap and signMapValid
        uioState = showMap
    end
    
    local t = ''
    local canExport = ( mapGenerated ) and ( not exportedTemplate ) and ( ____Disk_UUID ~= nil and ____Disk_UUID ~= '' )
    if signMapValid then
        uioState = true
        if showMap then
            t = "Hide Map"
        else
            t = "Display Map"
        end
    elseif canExport then
        t = 'Export new template'
        showMap = false
        uioState = true
    elseif exportedTemplate then
        t = 'Apply and reboot'
        showMap = false
        uioState = false
    elseif not networkValid then
        t = 'Waiting for network'
        showMap = false
        uioState = false
    else
        t = 'Invalid sign template'
        showMap = false
        uioState = false
    end
    
    HypertubeNode.UIO.MapToggle:setText( t )
    HypertubeNode.UIO.MapToggle:setState( uioState )
    HypertubeNode.UIO.MapToggle.showMap = showMap
    
end


---Changes the map/list display mode
---@param showMap boolean: (true) Show the map, (false) hide the map, show the list
function HypertubeNode.toggleMapDisplay( showMap )
    HypertubeNode.updateMapToggleMode( showMap )
end



---Draw the network map, can only do this if the map has been generated and the sign has the correct element layout
function HypertubeNode.UIO.drawMap()
    if HypertubeNode.mode ~= HypertubeNode.MODE_DESTINATION then return end
    if HypertubeNode.map == nil or type( HypertubeNode.map ) ~= "table" then return end
    
    local showMap = HypertubeNode.UIO.MapToggle.showMap
    local signs = HypertubeNode.signs
    
    
    if showMap then
        -- Show the map, hide the list
        local route = HypertubeNode.route
        local routeSet = route ~= nil
        
        listOpt.listUp:setZIndex( RSS_STATUS_ZINDEX_LIST_BACK )
        listOpt.listDn:setZIndex( RSS_STATUS_ZINDEX_LIST_BACK )
        
        for _, uio in pairs( listOpt.listUIOElements ) do
            uio:setZIndex( RSS_STATUS_ZINDEX_LIST_BACK )
        end
        
        for mID, mData in pairs( HypertubeNode.map ) do
            
            --{ element = eID, zOffset = zOff }
            
            local eID = mData.element
            local zOff = mData.zOffset
            
            rssElementSetZIndex( signs, eID, RSS_STATUS_ZINDEX_LIST_FRONT, zOff )
            
            local color = Color.GREY_0125
            local v = tonumber( mID )
            if routeSet then
                if v ~= nil then
                    -- element is a node, is it on the route?
                    if table.hasValue( route, v ) then
                        local mode = HypertubeNode.nodes[ v ].mode
                        if mode == HypertubeNode.MODE_DESTINATION then
                            if v == HypertubeNode.start then
                                color = Color.BLUE_SIGN_HIGH
                            elseif v == HypertubeNode.destination then
                                color = Color.GREEN_SIGN_HIGH
                            else
                                color = Color.CYAN_SIGN_LOW
                            end
                        else -- Junction
                            color = Color.CYAN_SIGN_LOW
                        end
                    end
                else
                    -- element is an edge, is it an edge on the route?
                    local l, r = string.find( mID, ":", 1, true )
                    local v1 = tonumber( string.sub( mID, 1, l - 1 ) )
                    local v2 = tonumber( string.sub( mID, r + 1, string.len( mID ) ) )
                    --print( mID )
                    --print( "\t", l, r, string.len( mID ) )
                    --print( "\t", v1, v2 )
                    if table.hasValue( route, v1 )
                    and table.hasValue( route, v2 ) then
                        color = Color.WHITE
                    end
                end
            else
                if v ~= nil then
                    if v == HypertubeNode.vertex then
                        color = Color.BLUE_SIGN_HIGH
                    elseif v == HypertubeNode.destination then
                        color = Color.GREEN_SIGN_HIGH
                    end
                end
            end
            
            rssElementSetColor( signs, eID, color )
            
        end
        
    else
        -- Show the list, hide the map
        
        for mID, mData in pairs( HypertubeNode.map ) do
            --{ element = eID, zOffset = zOff }
            local eID = mData.element
            local zOff = mData.zOffset
            rssElementSetZIndex( signs, eID, RSS_STATUS_ZINDEX_LIST_BACK, zOff )
        end
        
        for _, uio in pairs( listOpt.listUIOElements ) do
            uio:setZIndex( RSS_STATUS_ZINDEX_LIST_FRONT )
        end
        
        listOpt.listUp:setZIndex( RSS_STATUS_ZINDEX_LIST_FRONT )
        listOpt.listDn:setZIndex( RSS_STATUS_ZINDEX_LIST_FRONT )
        
    end
    
    
end

local function triggerMapToggle( edata )
    --print( "Trigger: mapToggle" )
    --if not listOpt.scrollUp:getState() then return end
    local newState = not HypertubeNode.UIO.MapToggle.showMap
    
    HypertubeNode.toggleMapDisplay( newState )
    
end



local function triggerListOptScrollUp( edata )
    --print( "Trigger: scrollUp" )
    --if not listOpt.scrollUp:getState() then return end
    
    local selected = listOpt.selected
    local start = listOpt.startAt
    
    if selected > 1 then
        selected = selected - 1
        if selected < start then
            start = selected
        end
    end
    
    listOpt.selected = selected
    listOpt.startAt = start
    
    HypertubeNode.destination = getDestinationByName( listOpt.listData[ listOpt.selected ] )
end


local function triggerListOptScrollDn( edata )
    --print( "Trigger: scrollDn" )
    --if not listOpt.scrollDn:getState() then return end
    
    local selected = listOpt.selected
    local listData = listOpt.listData
    local last = #listData
    local start = listOpt.startAt
    
    if selected < 1 then
        selected = 1
        start = 1
    elseif selected < last then
        selected = selected + 1
        local loLimit = RSS_EID_LIST_LAST - RSS_EID_LIST_FIRST + 1
        if selected > start + loLimit then
            start = selected - loLimit
        end
    end
    
    listOpt.selected = selected
    listOpt.startAt = start
    HypertubeNode.destination = getDestinationByName( listOpt.listData[ listOpt.selected ] )
end




local function triggerComputeRoute( edata )
    --print( "Trigger: ComputeRoute" )
    --if not HypertubeNode.UIO.ComputeRoute:getState() then return end
    if HypertubeNode.destination < 1 then return end
    
    local route = nil
    
    if HypertubeNode.UIO.ComputeRoute.aToB then
        local dest = HypertubeNode.nodes[ HypertubeNode.destination ]
        if dest == nil then return end
        
        HypertubeNode.setControlUIOSignalBlockStates( true, true, true )
        
        HypertubeNode.setNodeStatus( '...generating path...', Color.WHITE, Color.GREEN_SIGN_LOW )
        
        route = HypertubeNode.hyper_network:generate_path( HypertubeNode.vertex, HypertubeNode.destination )
        
        
    else
        if HypertubeNode.route == nil then return end
        HypertubeNode.setControlUIOSignalBlockStates( true, true, true )
        
        route = {}
        local last = #HypertubeNode.route
        for i = 1, last do
            route[ i ] = HypertubeNode.route[ 1 + last - i ]
        end
        
        local start = HypertubeNode.start
        local destination = HypertubeNode.destination
        HypertubeNode.start = destination
        HypertubeNode.destination = start
        
    end
    
    if #route ~= 0 then
        if false then
            print( "path:" )
            for _, v in pairs( route ) do
                print( "\t" .. tostring( v ) )
            end
            HypertubeNode.hyper_network:print()
        end
        
        HypertubeNode.changeComputeRouteMode( true )-- We may have gotten uno reversed
        HypertubeNode.setNodeStatus( '...programming nodes...' )
        HypertubeNode.programming = {}              -- Initialize the network programming dictionary
        for _, node in pairs( route ) do
            if node ~= HypertubeNode.vertex then    -- Don't add the start
                HypertubeNode.programming[ node ] = false
            end
        end
        HypertubeNode.start = HypertubeNode.vertex
        HypertubeNode.route = route
        HypertubeNode.route_timeout = calculateNetworkTimeoutTimestamp()
        Network.sendRouteComputed( route )
    else
        HypertubeNode.setNodeStatus( 'Unable to determine path', Color.YELLOW_SIGN_BRDRTEXT, Color.RED_SIGN_HIGH )
        HypertubeNode.setControlUIOSignalBlockStates( true, true, false )
    end
    
end


local function triggerResetRouting( edata )
    --print( "Trigger: ResetRouting" )
    --if not HypertubeNode.UIO.ResetRouting:getState() then return end
    Network.sendRouteReset()
end




local function triggerResetNetwork( edata )
    --print( "Trigger: ResetNetwork" )
    Network.sendAdminReset( true )
end




local function setUIOElementTextFromVertex( uio, vertex, default )
    local text = default
    if vertex == HypertubeNode.vertex then
        -- Itsa me!  Mario!
        text = HypertubeNode.name
    else
        local node = HypertubeNode.nodes[ vertex ]
        if node ~= nil then
            text = node.name
        end
    end
    uio:setText( text )
end




function HypertubeNode.setControlUIOSignalBlockStates( bScroll, bCompute, bReset )
    if HypertubeNode.mode ~= HypertubeNode.MODE_DESTINATION then return end
    listOpt.scrollUp:setSignalBlockState( bScroll )
    listOpt.scrollDn:setSignalBlockState( bScroll )
    HypertubeNode.UIO.ComputeRoute:setSignalBlockState( bCompute )
    HypertubeNode.UIO.ResetRouting:setSignalBlockState( bReset )
end


function HypertubeNode.setNodeStatus( text, fcolor, bcolor )
    if HypertubeNode.mode ~= HypertubeNode.MODE_DESTINATION then return end
    local zIndex = RSS_STATUS_ZINDEX_STATUS_BACK
    --print( text )
    if text ~= nil and text ~= '' then
        zIndex = RSS_STATUS_ZINDEX_STATUS_FRONT
        HypertubeNode.UIO.NodeStatus:setText( text )
        if fcolor ~= nil then   -- Only set the text and border element colors
            --print( 'HypertubeNode.setStatusState() fcolor = ' .. Color.ToString( fcolor ) )
            HypertubeNode.UIO.NodeStatus:setForeColorEx( fcolor, { zOffset =  1 } )
            HypertubeNode.UIO.NodeStatus:setForeColorEx( fcolor, { zOffset =  0 } )
        end
        if bcolor ~= nil then   -- only set the background image color
            --print( 'HypertubeNode.setStatusState() bcolor = ' .. Color.ToString( bcolor ) )
            HypertubeNode.UIO.NodeStatus:setForeColorEx( bcolor, { zOffset = -1 } )
        end
    end
    HypertubeNode.UIO.NodeStatus:setZIndex( zIndex )
end


function HypertubeNode.init()
    
    -- Get name, having a name tells us what subcomponents this node requires and how this node is handled
    getNodeName()
    
    -- Get vertex index, this must be unique in the network map; that will be validated later once we start IDENTing with other nodes
    getNodeVertex()
    
    -- Make sure this node has an isolated Component network before we start looking for other components
    getNodeRouter()
    
    -- Get the remote nodes we connect to
    getNodeConnections()
    
    
    -- Get the NetworkCard in the Computer
    HypertubeNode.networkcard = computer.getPCIDevicesByClass( ClassGroup.Networking.IntraNet.All )[ 1 ]
    if HypertubeNode.networkcard == nil then
        computer.panic( "Missing NetworkCard!" )
    end
    
    
    -- Get the RSS Sign[s] for Destinations
    local signs = component.getComponentsByClass( ClassGroup.Displays.Signs.ReallySimpleSigns.All )
    if HypertubeNode.mode == HypertubeNode.MODE_DESTINATION then
        if signs == nil or #signs < 1 then
            computer.panic( "Destination Node is missing Really Simple Sign(s)!" )
        end
        
        HypertubeNode.signs = signs
        
        -- Load the element layout
        local layout = generateRSSSignBaseData()
        generateRSSSignImport( layout, "rssimport_" .. layout.signSize ..  ".txt" )
        
        for _, sign in pairs( signs ) do
            -- Enforce the layout of the main elements
            layout:apply( sign )
            -- Quickly hide extra elements behind the blackground
            for eid = RSS_EID_BLACKGROUND + 1, sign:GetNumOfElements() - 1 do
                sign:Element_SetZIndex( RSS_STATUS_ZINDEX_HIDDEN, eid )
            end
            sign:Element_SetText( 'Initializing...', RSS_EID_STATUS_TEXT )
        end
        
    else
        if signs ~= nil and #signs > 0 then
            computer.panic( "Junction Nodes should not have any Really Simple Sign(s)!" )
        end
    end
    
    -- Get the Sizeable Panel[s] holding control buttons for Destinations
    local panels = component.getComponentsByClass( ClassGroup.ModulePanels.SizeableModulePanel )
    if HypertubeNode.mode == HypertubeNode.MODE_DESTINATION then
        if panels == nil or #panels < 1 then
            computer.panic( "Destination Node is missing Sizeable Panel[s]!" )
        end
    else
        if panels ~= nil and #panels > 0 then
            computer.panic( "Junction Nodes should not have any Sizeable Panel[s]!" )
        end
    end
    HypertubeNode.panels = panels
    
    
    -- Get the 1x1 Panel[s] holding the HypertubeNetwork reset button for the node
    local adminpanels = component.getComponentsByClass( { ClassGroup.ModulePanels.MCP_1Point_C, ClassGroup.ModulePanels.MCP_1Point_Center_C } )
    if adminpanels == nil or #adminpanels < 1 then
        computer.panic( "Node is missing 1x1 Module Panel[s]!  Destinations and Junctions should all have a local Network Reset button!" )
    end
    HypertubeNode.adminpanels = adminpanels
    
    
    -- Where are we going and how are we getting there?
    HypertubeNode.start = HypertubeNode.vertex          -- The start of the route
    HypertubeNode.destination = -1                      -- The end of the route
    HypertubeNode.route = nil                           -- The route through the network
    HypertubeNode.programming = nil                     -- Network programming dictionary - The node switch state for the route, this is tracked on the start of the route and the start will not set it's switches until all other nodes report they are ready
    
    
    -- This will auto-update with the last known network_size when the node is told to reboot
    HypertubeNode.hyper_network_size = ____ComputerSettings[ "network_size" ] or Network.Default.NETWORK_SIZE
    if HypertubeNode.hyper_network_size < Network.Default.NETWORK_SIZE then
        HypertubeNode.hyper_network_size = Network.Default.NETWORK_SIZE
    end
    HypertubeNode.hyper_network = AdjacencyMatrix( HypertubeNode.hyper_network_size, false )
    
    
    -- UIOElements
    
    if HypertubeNode.mode == HypertubeNode.MODE_DESTINATION then
        
        -- Node Status
        HypertubeNode.UIO.NodeStatus = createStatusCombinator( signs )
        HypertubeNode.setNodeStatus( 'Initializing...', Color.WHITE, Color.CYAN_SIGN_BACKGROUND )
        
        -- Current Location
        HypertubeNode.UIO.LocStart = createSimpleDisplayCombinator( signs, RSS_EID_LOC_START )
        setUIOElementTextFromVertex( HypertubeNode.UIO.LocStart, HypertubeNode.vertex, "Error" )
        
        -- Destination
        HypertubeNode.UIO.LocDestination = createSimpleDisplayCombinator( signs, RSS_EID_LOC_DEST )
        setUIOElementTextFromVertex( HypertubeNode.UIO.LocDestination, HypertubeNode.destination, "Select Destination" )
        
        -- Map toggle
        HypertubeNode.UIO.MapToggle = createUserControlCombinator(
            signs, panels,
            RSS_EID_MAP_TOGGLE, SMP_MI_MAP_TOGGLE,
            Color.CYAN_SIGN_HIGH, Color.CYAN_SIGN_LOW,
            Color.CYAN_BUTTON_HIGH, Color.CYAN_BUTTON_LOW,
            RSS_EID_MAP_TOGGLE + 1
        )
        HypertubeNode.toggleMapDisplay( false )   -- Make sure we are in the correct mode initially
        if not HypertubeNode.UIO.MapToggle:setSignalHandler( "Trigger", triggerMapToggle ) then
            computer.panic( "Could register for 'Trigger' signal on HypertubeNode.UIO.MapToggle" )
        end
        
        -- Compute Route
        HypertubeNode.UIO.ComputeRoute = createUserControlCombinator(
            signs, panels,
            RSS_EID_ROUTE_COMPUTE , SMP_MI_ROUTE_COMPUTE  ,
            Color.GREEN_SIGN_HIGH      , Color.GREEN_SIGN_LOW  ,
            Color.GREEN_BUTTON_HIGH    , Color.GREEN_BUTTON_LOW,
            RSS_EID_ROUTE_COMPUTE + 1
        )
        HypertubeNode.changeComputeRouteMode( true )   -- Make sure we are in the correct mode initially
        
        if not HypertubeNode.UIO.ComputeRoute:setSignalHandler( "Trigger", triggerComputeRoute ) then
            computer.panic( "Could register for 'Trigger' signal on HypertubeNode.UIO.ComputeRoute" )
        end
        
        -- Reset Route
        HypertubeNode.UIO.ResetRouting = createUserControlCombinator(
            signs, panels,
            RSS_EID_ROUTE_RESET  , SMP_MI_ROUTE_RESET  ,
            Color.RED_SIGN_HIGH  , Color.RED_SIGN_LOW  ,
            Color.RED_BUTTON_HIGH, Color.RED_BUTTON_LOW
        )
        
        if not HypertubeNode.UIO.ResetRouting:setSignalHandler( "Trigger", triggerResetRouting ) then
            computer.panic( "Could register for 'Trigger' signal on HypertubeNode.UIO.ResetRouting" )
        end
        
        --Destination List Options
        
        listOpt.listUp = createSimpleDisplayCombinator( signs, RSS_EID_LIST_INDICATOR_UP, Color.GREY_0250, Color.GREY_0125 )
        listOpt.listDn = createSimpleDisplayCombinator( signs, RSS_EID_LIST_INDICATOR_DN, Color.GREY_0250, Color.GREY_0125 )
        
        
        listOpt.scrollUp = createUserControlCombinator( signs, panels,
            RSS_EID_LIST_SELECT_UP  , SMP_MI_SELECT_UP       ,
            Color.ORANGE_SIGN_HIGH  , Color.ORANGE_SIGN_LOW  ,
            Color.ORANGE_BUTTON_HIGH, Color.ORANGE_BUTTON_LOW
        )
        
        if not listOpt.scrollUp:setSignalHandler( "Trigger", triggerListOptScrollUp ) then
            computer.panic( "Could register for 'Trigger' signal on HypertubeNode.UIO.ListOpt.scrollUp" )
        end
        
        
        listOpt.scrollDn = createUserControlCombinator( signs, panels,
            RSS_EID_LIST_SELECT_DN  , SMP_MI_SELECT_DN       ,
            Color.ORANGE_SIGN_HIGH  , Color.ORANGE_SIGN_LOW  ,
            Color.ORANGE_BUTTON_HIGH, Color.ORANGE_BUTTON_LOW
        )
        
        if not listOpt.scrollDn:setSignalHandler( "Trigger", triggerListOptScrollDn ) then
            computer.panic( "Could register for 'Trigger' signal on HypertubeNode.UIO.ListOpt.scrollDn" )
        end
        
        
        createListOptUIOElements( signs )
        
        
    end
    
    
    --Reset Network
    HypertubeNode.UIO.ResetNetwork = createUserControlCombinator(
        nil, adminpanels,
        nil, FMP_MI_NETWORK_RESET,
        nil, nil,
        nil, nil
    )
    
    if not HypertubeNode.UIO.ResetNetwork:setSignalHandler( "Trigger", triggerResetNetwork ) then
        computer.panic( "Could register for 'Trigger' signal on HypertubeNode.UIO.ResetNetwork" )
    end
    
    
    HypertubeNode.UIO.ResetNetwork:setForeColor( Color.RED_BUTTON_HIGH )
    Network.listenForNetworkEventsOn( HypertubeNode.networkcard )
    Network.sendAdminIdent( true ) -- initialIDENT
    
    
    if HypertubeNode.mode == HypertubeNode.MODE_DESTINATION then
        HypertubeNode.UIO.NodeStatus:setZIndex( RSS_STATUS_ZINDEX_STATUS_BACK )
    end
end




function HypertubeNode.handleEvent( edata )
    if edata == nil then return false end
    if edata[ 1 ] == nil then return false end
    if edata[ 2 ] == nil then return false end
    
    if UIO.UIOElements:eventHandler( edata )
    or Network.handleEvent( edata ) then
        return true
    end
    
    return false
end



--- Extracts the previous and next vertexes relative to this vertex from a vertex path
---@param path table: indexed path from start to destination
---@param vertex number: This vertex
---@return number?, number?: previous and next vertex IDs
local function extract_edges( path, vertex )
    for i, v in ipairs( path ) do
        if v == vertex then
            return path[ i - 1 ], path[ i + 1 ]
        end
    end
    return nil, nil
end


function HypertubeNode.resetSwitches()
    local switches = component.getComponentsByClass( ClassGroup.CircuitSwitches.All )
    for _, switch in pairs( switches ) do
        switch.isSwitchOn = false
    end
end


function HypertubeNode.setSwitches()
    local prev, after = extract_edges( HypertubeNode.route, HypertubeNode.vertex )
    local switches = component.getComponentsByClass( ClassGroup.CircuitSwitches.All )
    
    print( HypertubeNode.vertex, prev, after )
    
    for _, switch in pairs( switches ) do
        local n = switch.nick
        if n ~= nil and tonumber( n ) == prev then
            switch.isSwitchOn = true
        else
            switch.isSwitchOn = false
        end
    end
    
end


function HypertubeNode.UIO.update()
    if HypertubeNode.mode ~= HypertubeNode.MODE_DESTINATION then return end
    
    local startIsMe = HypertubeNode.start == HypertubeNode.vertex
    local destIsMe = HypertubeNode.destination == HypertubeNode.vertex
    local destValid = HypertubeNode.nodes[ HypertubeNode.destination ] ~= nil
    local routeSet = HypertubeNode.route ~= nil
    
    setUIOElementTextFromVertex( HypertubeNode.UIO.LocStart, HypertubeNode.start, "Error" )
    setUIOElementTextFromVertex( HypertubeNode.UIO.LocDestination, HypertubeNode.destination, "Select Destination" )
    -- Compute/Reverse Route:
    -- No route set:
    --  selected destination is valid, and
    --  this node is the start
    -- Route set:
    --  this node is the destination
    HypertubeNode.UIO.ComputeRoute:setState( destValid and ( ( startIsMe and not routeSet ) or ( destIsMe and routeSet ) ) )
    HypertubeNode.UIO.ResetRouting:setState( routeSet )
    -- The scroll buttons and list icons are managed by the List Options
    listOpt.updateElements()
    HypertubeNode.UIO.drawMap()
    
    
    if routeSet and startIsMe and computer.millis() > HypertubeNode.route_timeout then
        --HypertubeNode.route_timeout = math.huge -- Once we've changed the status message, don't bother constantly triggering it
        HypertubeNode.route_timeout = calculateNetworkTimeoutTimestamp()
        local t = ''
        for vertex, responded in pairs( HypertubeNode.programming ) do
            if not responded then
                if t ~= '' then t = t .. ', ' end
                t = t .. tostring( vertex )
            end
        end
        t = "Error: Node Timeout: " .. t
        HypertubeNode.setNodeStatus( t, Color.GREY_0250, Color.RED_SIGN_LOW )
    end
    
    
end



