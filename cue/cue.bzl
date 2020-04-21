CuePkg = provider(
    doc = "Collects files from cue_library for use in downstream cue_binary",
    fields = {
        "transitive_pkgs": "Cue pkg zips for this target and its dependencies",
    },
)

def _collect_transitive_pkgs(pkg, deps):
    "Cue evaluation requires all transitive .cue source files"
    return depset(
        [pkg],
        transitive = [dep[CuePkg].transitive_pkgs for dep in deps],
        # Provide .cue sources from dependencies first
        order = "postorder",
    )

def _cue_library_impl(ctx):
    """cue_library collects all transitive sources for given srcs and deps.
    It doesn't execute any actions.
    Args:
      ctx: The Bazel build context
    Returns:
      The cue_library rule.
    """

    args = ctx.actions.args()

    # Create the manifest input to cuepkg
    manifest = struct(
        importpath = ctx.attr.importpath,
        srcs = [src.path for src in ctx.files.srcs],
    )

    manifest_file = ctx.actions.declare_file(ctx.label.name + "~manifest")
    ctx.actions.write(manifest_file, manifest.to_json())
    args.add("-manifest", manifest_file.path)

    pkg = ctx.actions.declare_file(ctx.label.name + ".zip")
    args.add("-out", pkg.path)

    ctx.actions.run(
        mnemonic = "CuePkg",
        outputs = [pkg],
        inputs = [manifest_file] + ctx.files.srcs,
        executable = ctx.executable._cuepkg,
        arguments = [args],
    )

    return [
        DefaultInfo(
            files = depset([pkg]),
            runfiles = ctx.runfiles(files = [pkg]),
        ),
        CuePkg(
            transitive_pkgs = depset(
                [pkg],
                transitive = [dep[CuePkg].transitive_pkgs for dep in ctx.attr.deps],
                # Provide .cue sources from dependencies first
                order = "postorder",
            ),
        ),
    ]

def _zip_src(ctx):
    # Generate a zip file containing the src file
    src_zip = ctx.actions.declare_file(ctx.label.name + "~src.zip")

    args = ctx.actions.args()
    args.add(src_zip.path)
    args.add(ctx.file.src.path)

    ctx.actions.run_shell(
        mnemonic = "CueSrcZip",
        arguments = [args],
        command = "zip -o $1 $2",
        inputs = [ctx.file.src],
        outputs = [src_zip],
        use_default_shell_env = True,
    )

    return src_zip

def _pkg_merge(ctx, src_zip):
    merged = ctx.actions.declare_file(ctx.label.name + "~merged.zip")

    args = ctx.actions.args()
    args.add_joined(["-o", merged.path], join_with = "=")
    inputs = depset(
        [src_zip],
        transitive = [dep[CuePkg].transitive_pkgs for dep in ctx.attr.deps],
        # Provide .cue sources from dependencies first
        order = "postorder",
    )
    for dep in inputs.to_list():
        args.add(dep.path)

    ctx.actions.run(
        mnemonic = "CuePkgMerge",
        executable = ctx.executable._zipmerge,
        arguments = [args],
        inputs = inputs,
        outputs = [merged],
        use_default_shell_env = True,
    )

    return merged

def _cue_export(ctx, merged, output):
    """_cue_export performs an action to export a single Cue file."""

    # The Cue CLI expects inputs like
    # cue export <flags> <input_filename>
    args = ctx.actions.args()

    args.add(ctx.executable._cue.path)
    args.add(merged.path)
    args.add(ctx.file.src.path)
    args.add(output.path)

    if ctx.attr.escape:
        args.add("--escape")
    #if ctx.attr.ignore:
    #    args.add("--ignore")
    #if ctx.attr.simplify:
    #    args.add("--simplify")
    #if ctx.attr.trace:
    #    args.add("--trace")
    #if ctx.attr.verbose:
    #    args.add("--verbose")
    #if ctx.attr.debug:
    #    args.add("--debug")

    args.add_joined(["--out", ctx.attr.output_format], join_with = "=")
    #args.add(input.path)

    ctx.actions.run_shell(
        mnemonic = "CueExport",
        tools = [ctx.executable._cue],
        arguments = [args],
        command = """
set -euo pipefail

CUE=$1; shift
PKGZIP=$1; shift
SRC=$1; shift
OUT=$1; shift

unzip -q ${PKGZIP}
${CUE} export $@ ${SRC} > ${OUT}
""",
        inputs = [merged],
        outputs = [output],
        use_default_shell_env = True,
    )

def _cue_binary_impl(ctx):
    src_zip = _zip_src(ctx)
    merged = _pkg_merge(ctx, src_zip)
    _cue_export(ctx, merged, ctx.outputs.export)
    return DefaultInfo(
        files = depset([ctx.outputs.export]),
        runfiles = ctx.runfiles(files = [ctx.outputs.export]),
    )



_cue_deps_attr = attr.label_list(
    doc = "cue_library targets to include in the evaluation",
    providers = [CuePkg],
    allow_files = False,
)

_cue_library_attrs = {
    "srcs": attr.label_list(
        doc = "Cue source files",
        allow_files = [".cue"],
        allow_empty = False,
        mandatory = True,
    ),
    "deps": _cue_deps_attr,
    "importpath": attr.string(
        doc = "Cue import path under pkg/",
        mandatory = True,
    ),
    "_cuepkg": attr.label(
        default = Label("//cue/tools/cuepkg"),
        executable = True,
        allow_single_file = True,
        cfg = "host",
    ),
}

cue_library = rule(
    implementation = _cue_library_impl,
    attrs = _cue_library_attrs,
)

def _strip_extension(path):
    """Removes the final extension from a path."""
    components = path.split(".")
    components.pop()
    return ".".join(components)

def _cue_binary_outputs(src, output_name, output_format):
    """Get map of cue_binary outputs.
    Note that the arguments to this function are named after attributes on the rule.
    Args:
      src: The rule's `src` attribute
      output_name: The rule's `output_name` attribute
      output_format: The rule's `output_format` attribute
    Returns:
      Outputs for the cue_binary
    """

    outputs = {
        "export": output_name or _strip_extension(src.name) + "." + output_format,
    }

    return outputs

_cue_binary_attrs = {
    "src": attr.label(
        doc = "Cue entrypoint file",
        mandatory = True,
        allow_single_file = [".cue"],
    ),
    "escape": attr.bool(
        default = False,
        doc = "Use HTML escaping.",
    ),
    #debug            give detailed error info
    #ignore           proceed in the presence of errors
    #simplify         simplify output
    #trace            trace computation
    #verbose          print information about progress
    "output_name": attr.string(
        doc = """Name of the output file, including the extension.
By default, this is based on the `src` attribute: if `foo.cue` is
the `src` then the output file is `foo.json.`.
You can override this to be any other name.
Note that some tooling may assume that the output name is derived from
the input name, so use this attribute with caution.""",
        default = "",
    ),
    "output_format": attr.string(
        doc = "Output format",
        default = "json",
        values = [
            "json",
            "yaml",
        ],
    ),
    "deps": _cue_deps_attr,
    "_cue": attr.label(
        default = Label("//cue:cue_runtime"),
        executable = True,
        allow_single_file = True,
        cfg = "host",
    ),
    "_zipmerge": attr.label(
        default = Label("@io_rsc_zipmerge//:zipmerge"),
        executable = True,
        allow_single_file = True,
        cfg = "host",
    )
}

cue_binary = rule(
    implementation = _cue_binary_impl,
    attrs = _cue_binary_attrs,
    outputs = _cue_binary_outputs,
)