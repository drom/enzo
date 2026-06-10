const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("elastic_pipe", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    const exe = b.addExecutable(.{
        .name = "elastic_pipe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elastic_pipe", .module = mod },
            },
        }),
    });

    // Run Verilator
    // Verilog Parameters
    const dw_val = b.option(
        u32,
        "DW",
        "Data Bus width parameter",
    ) orelse 32;

    const opt_flag = switch (optimize) {
        .Debug => "-O0",
        .ReleaseSafe, .ReleaseFast => "-O3",
        .ReleaseSmall => "-Os",
    };

    const run_verilator = b.addSystemCommand(&.{
        "verilator",
        "-cc",
        "--trace",
        "--Mdir",
        "obj_dir",
        b.fmt("-GDW={d}", .{dw_val}),
        "vsrc/top.v",
    });
    const run_make = b.addSystemCommand(&.{
        "make",
        "-j",
        "6",
        "-C",
        "obj_dir",
        "-f",
        "Vtop.mk",
        "CXX=zig c++",
        "LINK=zig c++",
        b.fmt("OPT_FAST={s}", .{opt_flag}),
        b.fmt("OPT_SLOW={s}", .{opt_flag}),
    });

    run_make.step.dependOn(&run_verilator.step);
    exe.step.dependOn(&run_make.step);
    exe.root_module.link_libc = true;
    exe.root_module.link_libcpp = true;
    const vroot = "/tools/verilator/latest/share/verilator/include";
    exe.root_module.addIncludePath(.{ .cwd_relative = vroot });
    exe.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ vroot, "vltstd" }) });
    exe.root_module.addIncludePath(.{ .cwd_relative = "obj_dir" });
    exe.root_module.addObjectFile(b.path("obj_dir/Vtop__ALL.a"));
    exe.root_module.addCSourceFiles(.{
        .root = .{ .cwd_relative = vroot },
        .files = &.{
            "verilated.cpp",
            "verilated_vcd_c.cpp",
            "verilated_threads.cpp",
        },
        .flags = &[_][]const u8{"-std=c++17"},
    });

    // zim_wrapper compiled with DW define so pin types match Verilator.
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/zim_wrapper.cpp"),
        .flags = &[_][]const u8{ "-std=c++17", b.fmt("-DDW={d}", .{dw_val}) },
    });

    // Comptime DW into Zig via build_options module.
    const build_opts = b.addOptions();
    build_opts.addOption(u32, "DW", dw_val);
    exe.root_module.addOptions("build_options", build_opts);

    // ENZO dependency
    // fetch the dependency from the .zon file
    const enzo_dependency = b.dependency("enzo_dep", .{
        .target = target,
        .optimize = optimize,
    });

    // extract module form the dependency using exported name
    const enzo_module = enzo_dependency.module("enzo");

    // add the module to our exacutable root
    exe.root_module.addImport("enzo", enzo_module);

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
