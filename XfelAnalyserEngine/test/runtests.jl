import ReTest: retest
import XfelAnalyserEngine

include("XfelAnalyserEngineTests.jl")

retest(XfelAnalyserEngine, XfelAnalyserEngineTests)
