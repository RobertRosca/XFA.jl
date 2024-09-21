module ImNodes

import CImGui as ig

ImNodesContext = ig.ImNodesContext
ImNodesPinShape = ig.ImNodesPinShape

ImNodesPinShape_Circle = ig.ImNodesPinShape_Circle
ImNodesPinShape_CircleFilled = ig.ImNodesPinShape_CircleFilled
ImNodesPinShape_Triangle = ig.ImNodesPinShape_Triangle
ImNodesPinShape_TriangleFilled = ig.ImNodesPinShape_TriangleFilled
ImNodesPinShape_Quad = ig.ImNodesPinShape_Quad
ImNodesPinShape_QuadFilled = ig.ImNodesPinShape_QuadFilled

ImNodesMiniMapLocation_BottomLeft = ig.ImNodesMiniMapLocation_BottomLeft
ImNodesMiniMapLocation_BottomRight = ig.ImNodesMiniMapLocation_BottomRight
ImNodesMiniMapLocation_TopLeft = ig.ImNodesMiniMapLocation_TopLeft
ImNodesMiniMapLocation_TopRight = ig.ImNodesMiniMapLocation_TopRight

CreateContext = ig.imnodes_CreateContext
DestroyContext = ig.imnodes_DestroyContext

BeginNodeEditor = ig.imnodes_BeginNodeEditor
EndNodeEditor = ig.imnodes_EndNodeEditor

BeginNode = ig.imnodes_BeginNode
EndNode = ig.imnodes_EndNode

Link = ig.imnodes_Link

BeginInputAttribute = ig.imnodes_BeginInputAttribute
EndInputAttribute = ig.imnodes_EndInputAttribute
BeginOutputAttribute = ig.imnodes_BeginOutputAttribute
EndOutputAttribute = ig.imnodes_EndOutputAttribute

BeginNodeTitleBar = ig.imnodes_BeginNodeTitleBar
EndNodeTitleBar = ig.imnodes_EndNodeTitleBar

function MiniMap()
    ig.imnodes_MiniMap(0.2, ImNodesMiniMapLocation_BottomRight, C_NULL, C_NULL)
end

end
