#=
What I want:
- Broadly similar design to metropc (but probably different naming).
- Optional separation between visualization and function return value.
- Allow sub-variables for 'instrumenting' of top-level variables. This makes it
  much easier to build complicated pipelines because it removes the overhead of
  'plumbing' (creating new functions and explicitly stating dependencies etc).
- With Dagger there is a possibility of passing EagerThunk's directly to the
  functions, but we cannot rely on it for specifying dependencies on
  sub-variables. So there's probably no way around specifying them with
  e.g. user strings like
  `karabo"MID_DET_AGIPD1M/FOO/BAR:daqOutput[image.data]"` or #`view"foo"`.
- Need a name that is not too weird, ideally we'd use View but that conflicts
  with Julia's @view. Dagger uses Thunk, but that's too weird IMO. Use Variable
  to match with DAMNIT.
=#

#=
Possible context design with Dagger:
=#
