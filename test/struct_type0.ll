; -gepin -simvar
%struct.proc = type { i32, i32 }

define dso_local i32 @main() {
entry:
  %vim = alloca %struct.proc, align 4
  %pid = getelementptr inbounds %struct.proc, %struct.proc* %vim, i64 0, i32 0
  store i32 12, i32* %pid, align 4
  %nice = getelementptr inbounds %struct.proc, %struct.proc* %vim, i64 0, i32 1
  store i32 23, i32* %nice, align 4
  call void @foo(%struct.proc* nonnull %vim)
  ret i32 0
}

declare dso_local void @foo(%struct.proc*)
