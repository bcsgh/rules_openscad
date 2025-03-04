"""Library used to handle OpenSCAD files in Bazel

There are 3 rules in this library:
- scad_library(): Create a library object that other libraries or objects can
  link to
- scad_object(): Create a 3D object that can be rendered
- scad_test(): Test your 3D object by comparing it with golden models that are
  submitted into git
"""

srcs_attrs = attr.label_list(
    mandatory = True,
    allow_empty = False,
    allow_files = [".scad"],
    doc = "Filenames for the files that are included in this rule",
)

deps_attrs = attr.label_list(
    mandatory = False,
    allow_empty = True,
    providers = [DefaultInfo],
    doc = "Other libraries that the files on this rule depend on",
)

def _get_openscad_executable(ctx):
    for file in ctx.attr._openscad_files.files.to_list():
        if file.basename == "AppRun":
            # The OpenSCAD version is an AppImage, this file is the entrypoint
            return file
    return "OS not supported"

def _scad_library_impl(ctx):
    files = depset(
        ctx.files.srcs,
        transitive = [dep[DefaultInfo].files for dep in ctx.attr.deps])
    return [DefaultInfo(
        files = files,
        runfiles = ctx.runfiles(
            files = files.to_list(),
            collect_data = True,
        ),
    )]

scad_library = rule(
    implementation = _scad_library_impl,
    attrs = {
        "srcs": srcs_attrs,
        "deps": deps_attrs,
    },
    doc = """
Create a 3D library to wrap OpenSCAD code to be linked by other libraries or objects
""",
)

def _scad_object_impl(ctx):
    if ctx.outputs.out:
        stl_output = ctx.actions.declare_file(ctx.outputs.out.basename)
    else:
        stl_output = ctx.actions.declare_file(ctx.label.name + ".stl")
    stl_inputs = ctx.files.srcs
    deps = []
    for one_transitive_dep in [dep[DefaultInfo].files for dep in ctx.attr.deps]:
        deps += one_transitive_dep.to_list()
    ctx.actions.run(
        outputs = [stl_output],
        inputs = stl_inputs + deps,
        executable = _get_openscad_executable(ctx),
        tools = ctx.attr._openscad_files.files,
        # use_default_shell_env = True,
        arguments = [
            "--export-format=stl",
            "-o%s" % stl_output.path,
        ] + [input.short_path for input in stl_inputs],
    )
    files = depset(
        ctx.files.srcs + [stl_output],
        transitive = [dep[DefaultInfo].files for dep in ctx.attr.deps])
    return [DefaultInfo(
        files = files,
        runfiles = ctx.runfiles(
            files = files.to_list(),
            collect_data = True,
        ),
    )]

scad_object = rule(
    implementation = _scad_object_impl,
    attrs = {
        "srcs": srcs_attrs,
        "deps": deps_attrs,
        "out": attr.output(
            doc = "The name of the generated file.",
        ),
        "_openscad_files": attr.label(
            default = Label("//:openscad"),
            cfg = "exec",
        ),
    },
    doc = """
Create a 3D object based on the provided code and libraries
""",
)

def _scad_test_impl(ctx):
    # Create the execution environment to run the test
    unittest_script = ctx.actions.declare_file(
        "%s_unittest_script.sh" % ctx.label.name)
    unittest_binary = ctx.files._unittest_binary[0]
    if unittest_binary.is_source:
        unittest_binary = ctx.files._unittest_binary[1]
    ctx.actions.write(
        output = unittest_script,
        is_executable = True,
        content = "#!/bin/bash\n" + " ".join([
            "env; pwd; find -type f; find -type l;",
            unittest_binary.short_path,
            "--openscad_command '%s'" % _get_openscad_executable(ctx).short_path,
            "--scad_file_under_test %s" % ctx.files.library_under_test[0].path,
            " ".join([
                "--testcases \"%s#%s/%s\"" % (
                    testcase,
                    golden.label.package if golden.label.package else ".",
                    golden.label.name
                ) for (golden, testcase) in ctx.attr.tests.items()]),
            " ".join([
                "--assertion_check \"%s\"" % assertion
                for assertion in ctx.attr.assertions]),
            "--scad_code_file scad.code",
            "--render_stl ${TEST_UNDECLARED_OUTPUTS_DIR}/render.stl",
            "--new_parts_stl ${TEST_UNDECLARED_OUTPUTS_DIR}/new_parts.stl",
            "--missing_parts_stl ${TEST_UNDECLARED_OUTPUTS_DIR}/missing_parts.stl",
        ])
    )

    # The test will be executed once we create the DefaultInfo object
    return [
        DefaultInfo(
            executable = unittest_script,
            runfiles = ctx.runfiles(
                files = [],
                transitive_files = depset(
                    direct = ctx.files.tests + [unittest_script],
                    transitive = [
                        ctx.attr.library_under_test.files,
                        depset([
                            ctx.attr._unittest_binary[PyRuntimeInfo].interpreter,
                        ]),
                        ctx.attr._unittest_binary.files,
                        ctx.attr._unittest_binary[PyInfo].transitive_sources,
                        ctx.attr._unittest_binary[PyRuntimeInfo].files,
                        ctx.attr._openscad_files.files,
                    ],
                ),
            ),
        ),
        RunEnvironmentInfo({"APPIMAGE_EXTRACT_AND_RUN": "1"}),
    ]

scad_test = rule(
    implementation = _scad_test_impl,
    test = True,
    executable = True,
    attrs = {
        "library_under_test": attr.label(
            mandatory = True,
            executable = False,
            allow_rules = ["scad_library"],
            doc = """
Library that will be imported when compiling any code under test
""",
        ),
        "tests": attr.label_keyed_string_dict(
            mandatory = True,
            allow_empty = False,
            allow_files = [".stl"],
            doc = """
List of testcases. The key is the filename of the golden STL for this testcase,
and the value is the code under test (which object will be compiled) without the
library under test being imported (that's done by the  framework)

The test will fail if any of the code snippets under test create a result that
is different from the golden STL for that testcase
""",
        ),
        "assertions": attr.string_list(
            mandatory = False,
            allow_empty = True,
            doc = """
List of code snippets that are expected to fail an assertion. The test will fail
if any of these fail to trigger an assertion
""",
        ),
        "_unittest_binary": attr.label(
            default = Label("//:scad_unittest"),
            executable = True,
            cfg = "exec",
        ),
        "_openscad_files": attr.label(
            default = Label("//:openscad"),
            cfg = "exec",
        ),
    },
    doc = """
Test for 3D objects and libraries

The test works by compiling the code provided in the tests attribute, and
comparing it with the provided golden STL file. If the 2 objects are equal then
the test passes, if they aren't then the test fails. 2 objects (A and B) are
defined equal if A-B is empty (B includes A) and B-A is empty (A includes B)

The test also checks that assertions are triggered for all the code provided in
the assertions list
""",
)
