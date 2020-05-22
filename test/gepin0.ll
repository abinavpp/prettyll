; -gepin -simvar
define dso_local void @test(float* nocapture %a, float* nocapture readonly %b, float* nocapture readonly %c, i64 %index) local_unnamed_addr {
entry:
  %0 = getelementptr inbounds float, float* %b, i64 %index
  %1 = bitcast float* %0 to <4 x float>*
  %wide.load = load <4 x float>, <4 x float>* %1, align 4
  %2 = getelementptr inbounds float, float* %c, i64 %index
  %3 = bitcast float* %2 to <4 x float>*
  %wide.load35 = load <4 x float>, <4 x float>* %3, align 4
  %4 = fadd <4 x float> %wide.load, %wide.load35
  ret void
}
