import ReTest: retest
import XfaEngine

include("XfaEngineTests.jl")

retest(XfaEngine, XfaEngineTests)
