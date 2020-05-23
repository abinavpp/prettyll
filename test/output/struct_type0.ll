; -gepin -simvar
%struct.proc = type { i32, i32 }

define dso_local i32 @main() {
entry:
  %vim = alloca %struct.proc, align 4
  store i32 12, i32* (gep %struct.proc* %vim[0, 0]), align 4
  store i32 23, i32* (gep %struct.proc* %vim[0, 1]), align 4
  call void @foo(%struct.proc* nonnull %vim)
  ret i32 0
}

declare dso_local void @foo(%struct.proc*)
