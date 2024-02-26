module ImNodes

import LibCImGui as L

ImNodesContext = L.ImNodesContext
ImNodesPinShape = L.ImNodesPinShape

ImNodesPinShape_Circle = L.ImNodesPinShape_Circle
ImNodesPinShape_CircleFilled = L.ImNodesPinShape_CircleFilled
ImNodesPinShape_Triangle = L.ImNodesPinShape_Triangle
ImNodesPinShape_TriangleFilled = L.ImNodesPinShape_TriangleFilled
ImNodesPinShape_Quad = L.ImNodesPinShape_Quad
ImNodesPinShape_QuadFilled = L.ImNodesPinShape_QuadFilled

ImNodesMiniMapLocation_BottomLeft = L.ImNodesMiniMapLocation_BottomLeft
ImNodesMiniMapLocation_BottomRight = L.ImNodesMiniMapLocation_BottomRight
ImNodesMiniMapLocation_TopLeft = L.ImNodesMiniMapLocation_TopLeft
ImNodesMiniMapLocation_TopRight = L.ImNodesMiniMapLocation_TopRight

CreateContext = L.imnodes_CreateContext
DestroyContext = L.imnodes_DestroyContext

BeginNodeEditor = L.imnodes_BeginNodeEditor
EndNodeEditor = L.imnodes_EndNodeEditor

BeginNode = L.imnodes_BeginNode
EndNode = L.imnodes_EndNode

Link = L.imnodes_Link

BeginInputAttribute = L.imnodes_BeginInputAttribute
EndInputAttribute = L.imnodes_EndInputAttribute
BeginOutputAttribute = L.imnodes_BeginOutputAttribute
EndOutputAttribute = L.imnodes_EndOutputAttribute

BeginNodeTitleBar = L.imnodes_BeginNodeTitleBar
EndNodeTitleBar = L.imnodes_EndNodeTitleBar

function MiniMap()
    L.imnodes_MiniMap(0.2, ImNodesMiniMapLocation_BottomRight, C_NULL, C_NULL)
end

end
