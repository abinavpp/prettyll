; -gepin -simvar
define dso_local void @test(float* nocapture %a, float* nocapture readonly %b, float* nocapture readonly %c, i64 %index) local_unnamed_addr {
entry:
  %4 = fadd <4 x float> (gep float* %b[%index]), (gep float* %c[%index])
  ret void
}
