# Copyright Google Inc. All Rights Reserved.
#
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file at https://angular.io/license
"""Implementation of the ng_module rule.
"""

load(":rules_typescript.bzl",
    "tsc_wrapped_tsconfig",
    "COMMON_ATTRIBUTES",
    "COMMON_OUTPUTS",
    "compile_ts",
    "DEPS_ASPECTS",
    "ts_providers_dict_to_struct",
    "json_marshal",
)

def _basename_of(ctx, file):
  ext_len = len(".ts")
  if file.short_path.endswith(".ng.html"):
    ext_len = len(".ng.html")
  elif file.short_path.endswith(".html"):
    ext_len = len(".html")
  return file.short_path[len(ctx.label.package) + 1:-ext_len]

# Calculate the expected output of the template compiler for every source in
# in the library. Most of these will be produced as empty files but it is
# unknown, without parsing, which will be empty.
def _expected_outs(ctx):
  devmode_js_files = []
  closure_js_files = []
  declaration_files = []
  summary_files = []

  factory_basename_set = depset([_basename_of(ctx, src) for src in ctx.files.factories])

  for src in ctx.files.srcs + ctx.files.assets:
    package_prefix = ctx.label.package + "/" if ctx.label.package else ""

    # Strip external repository name from path if src is from external repository
    # If src is from external repository, it's short_path will be ../<external_repo_name>/...
    short_path = src.short_path if src.short_path[0:2] != ".." else "/".join(src.short_path.split("/")[2:])

    if short_path.endswith(".ts") and not short_path.endswith(".d.ts"):
      basename = short_path[len(package_prefix):-len(".ts")]
      if len(factory_basename_set) == 0 or basename in factory_basename_set:
        devmode_js = [
            ".ngfactory.js",
            ".ngsummary.js",
            ".js",
        ]
        summaries = [".ngsummary.json"]
      else:
        devmode_js = [".js"]
        summaries = []
    elif short_path.endswith(".css"):
      basename = short_path[len(package_prefix):-len(".css")]
      devmode_js = [
          ".css.shim.ngstyle.js",
          ".css.ngstyle.js",
      ]
      summaries = []

    else:
      continue

    filter_summaries = ctx.attr.filter_summaries
    closure_js = [f.replace(".js", ".closure.js") for f in devmode_js if not filter_summaries or not f.endswith(".ngsummary.js")]
    declarations = [f.replace(".js", ".d.ts") for f in devmode_js]

    devmode_js_files += [ctx.new_file(ctx.bin_dir, basename + ext) for ext in devmode_js]
    closure_js_files += [ctx.new_file(ctx.bin_dir, basename + ext) for ext in closure_js]
    declaration_files += [ctx.new_file(ctx.bin_dir, basename + ext) for ext in declarations]
    summary_files += [ctx.new_file(ctx.bin_dir, basename + ext) for ext in summaries]

  i18n_messages_files = [ctx.new_file(ctx.genfiles_dir, ctx.label.name + "_ngc_messages.xmb")]

  return struct(
    closure_js = closure_js_files,
    devmode_js = devmode_js_files,
    declarations = declaration_files,
    summaries = summary_files,
    i18n_messages = i18n_messages_files,
  )

def _ivy_tsconfig(ctx, files, srcs, **kwargs):
  return _ngc_tsconfig_helper(ctx, files, srcs, True, **kwargs)

def _ngc_tsconfig(ctx, files, srcs, **kwargs):
  return _ngc_tsconfig_helper(ctx, files, srcs, False, **kwargs)

def _ngc_tsconfig_helper(ctx, files, srcs, enable_ivy, **kwargs):
  outs = _expected_outs(ctx)
  if "devmode_manifest" in kwargs:
    expected_outs = outs.devmode_js + outs.declarations + outs.summaries
  else:
    expected_outs = outs.closure_js

  return dict(tsc_wrapped_tsconfig(ctx, files, srcs, **kwargs), **{
      "angularCompilerOptions": {
          "enableResourceInlining": ctx.attr.inline_resources,
          "generateCodeForLibraries": False,
          "allowEmptyCodegenFiles": True,
          "enableSummariesForJit": True,
          "enableIvy": enable_ivy,
          "fullTemplateTypeCheck": ctx.attr.type_check,
          # FIXME: wrong place to de-dupe
          "expectedOut": depset([o.path for o in expected_outs]).to_list()
      }
  })

def _collect_summaries_aspect_impl(target, ctx):
  results = depset(target.angular.summaries if hasattr(target, "angular") else [])

  # If we are visiting empty-srcs ts_library, this is a re-export
  srcs = ctx.rule.attr.srcs if hasattr(ctx.rule.attr, "srcs") else []

  # "re-export" rules should expose all the files of their deps
  if not srcs:
    for dep in ctx.rule.attr.deps:
      if (hasattr(dep, "angular")):
        results = depset(dep.angular.summaries, transitive = [results])

  return struct(collect_summaries_aspect_result = results)

_collect_summaries_aspect = aspect(
    implementation = _collect_summaries_aspect_impl,
    attr_aspects = ["deps"],
)

# Extra options passed to Node when running ngc.
_EXTRA_NODE_OPTIONS_FLAGS = [
    # Expose the v8 garbage collection API to JS.
    "--node_options=--expose-gc"
]

def ngc_compile_action(ctx, label, inputs, outputs, messages_out, tsconfig_file,
                       node_opts, locale=None, i18n_args=[]):
  """Helper function to create the ngc action.

  This is exposed for google3 to wire up i18n replay rules, and is not intended
  as part of the public API.

  Args:
    ctx: skylark context
    label: the label of the ng_module being compiled
    inputs: passed to the ngc action's inputs
    outputs: passed to the ngc action's outputs
    messages_out: produced xmb files
    tsconfig_file: tsconfig file with settings used for the compilation
    node_opts: list of strings, extra nodejs options.
    locale: i18n locale, or None
    i18n_args: additional command-line arguments to ngc

  Returns:
    the parameters of the compilation which will be used to replay the ngc action for i18N.
  """

  mnemonic = "AngularTemplateCompile"
  progress_message = "Compiling Angular templates (ngc) %s" % label

  if locale:
    mnemonic = "AngularI18NMerging"
    supports_workers = "0"
    progress_message = ("Recompiling Angular templates (ngc) %s for locale %s" %
                        (label, locale))
  else:
    supports_workers = str(int(ctx.attr._supports_workers))

  arguments = (list(_EXTRA_NODE_OPTIONS_FLAGS) +
               ["--node_options=%s" % opt for opt in node_opts])
  # One at-sign makes this a params-file, enabling the worker strategy.
  # Two at-signs escapes the argument so it's passed through to ngc
  # rather than the contents getting expanded.
  if supports_workers == "1":
    arguments += ["@@" + tsconfig_file.path]
  else:
    arguments += ["-p", tsconfig_file.path]

  arguments += i18n_args

  ctx.action(
      progress_message = progress_message,
      mnemonic = mnemonic,
      inputs = inputs,
      outputs = outputs,
      arguments = arguments,
      executable = ctx.executable.compiler,
      execution_requirements = {
          "supports-workers": supports_workers,
      },
  )

  if messages_out != None:
    ctx.action(inputs = list(inputs),
               outputs = messages_out,
               executable = ctx.executable._ng_xi18n,
               arguments = (_EXTRA_NODE_OPTIONS_FLAGS +
                            [tsconfig_file.path] +
                            # The base path is bin_dir because of the way the ngc
                            # compiler host is configured. So we need to explictily
                            # point to genfiles/ to redirect the output.
                            ["../genfiles/" + messages_out[0].short_path]),
               progress_message = "Extracting Angular 2 messages (ng_xi18n)",
               mnemonic = "Angular2MessageExtractor")

  if not locale and not ctx.attr.no_i18n:
    return struct(
        label = label,
        tsconfig = tsconfig_file,
        inputs = inputs,
        outputs = outputs,
        compiler = ctx.executable.compiler,
    )

  return None

def _compile_action(ctx, inputs, outputs, messages_out, tsconfig_file, node_opts):
  # Give the Angular compiler all the user-listed assets
  file_inputs = list(ctx.files.assets)

  # The compiler only needs to see TypeScript sources from the npm dependencies,
  # but may need to look at package.json and ngsummary.json files as well.
  if hasattr(ctx.attr, "node_modules"):
    file_inputs += [f for f in ctx.files.node_modules
                    if f.path.endswith(".ts") or f.path.endswith(".json")]

  # If the user supplies a tsconfig.json file, the Angular compiler needs to read it
  if hasattr(ctx.attr, "tsconfig") and ctx.file.tsconfig:
    file_inputs.append(ctx.file.tsconfig)

  # Collect the inputs and summary files from our deps
  action_inputs = depset(file_inputs,
      transitive = [inputs] + [dep.collect_summaries_aspect_result for dep in ctx.attr.deps
                    if hasattr(dep, "collect_summaries_aspect_result")])

  return ngc_compile_action(ctx, ctx.label, action_inputs, outputs, messages_out, tsconfig_file, node_opts)


def _prodmode_compile_action(ctx, inputs, outputs, tsconfig_file, node_opts):
  outs = _expected_outs(ctx)
  return _compile_action(ctx, inputs, outputs + outs.closure_js, outs.i18n_messages, tsconfig_file, node_opts)

def _devmode_compile_action(ctx, inputs, outputs, tsconfig_file, node_opts):
  outs = _expected_outs(ctx)
  compile_action_outputs = outputs + outs.devmode_js + outs.declarations + outs.summaries
  _compile_action(ctx, inputs, compile_action_outputs, None, tsconfig_file, node_opts)

def _ts_expected_outs(ctx, label):
  # rules_typescript expects a function with two arguments, but our
  # implementation doesn't use the label
  _ignored = [label]
  return _expected_outs(ctx)

def _write_bundle_index(ctx):
  # Provide a default for the flat_module_out_file attribute.
  # We cannot use the default="" parameter of ctx.attr because the value is calculated
  # from other attributes (name)
  flat_module_out_file = ctx.attr.flat_module_out_file if ctx.attr.flat_module_out_file else "%s_public_index" % ctx.label.name

  tsconfig_file = ctx.actions.declare_file("%s.tsconfig.json" % flat_module_out_file)
  metadata_file = ctx.actions.declare_file("%s.metadata.json" % flat_module_out_file)
  typings_file = ctx.actions.declare_file("%s.d.ts" % flat_module_out_file)
  index_file = ctx.actions.declare_file("%s.js" % flat_module_out_file)

  tsconfig = dict(tsc_wrapped_tsconfig(ctx, ctx.files.srcs, ctx.files.srcs), **{
    "angularCompilerOptions": {
      "flatModuleOutFile": flat_module_out_file,
    },
  })
  if not ctx.attr.module_name:
    fail("Only ng_module with a module_name attribute should be exposed as flat module")
  tsconfig["angularCompilerOptions"]["flatModuleId"] = ctx.attr.module_name

  entry_point = ctx.attr.entry_point if ctx.attr.entry_point else "index.ts"
  # createBundleIndexHost in bundle_index_host.ts will throw if the "files" has more than one entry.
  # We don't want to fail() here, however, because not all ng_module's will have the bundle index written.
  # So we make the assumption that the index.ts file in the highest parent directory is the entry point.
  index = None

  for f in tsconfig["files"]:
    if f.endswith("/" + entry_point):
      if not index or len(f) < len(index):
        index = f

  if index:
    tsconfig["files"] = [index]

  ctx.actions.write(tsconfig_file, json_marshal(tsconfig))

  ctx.action(
      progress_message = "Producing metadata for bundle %s" % ctx.label.name,
      executable = ctx.executable._index_bundler,
      inputs = ctx.files.srcs + [tsconfig_file],
      outputs = [metadata_file, typings_file, index_file],
      arguments = ["-p", tsconfig_file.path],
  )
  return struct(
      module_name = ctx.attr.module_name,
      metadata_file = metadata_file,
      typings_file = typings_file,
      index_file = index_file)

def ng_module_impl(ctx, ts_compile_actions, ivy = False):
  """Implementation function for the ng_module rule.

  This is exposed so that google3 can have its own entry point that re-uses this
  and is not meant as a public API.

  Args:
    ctx: the skylark rule context
    ts_compile_actions: generates all the actions to run an ngc compilation
    ivy: if True, run the compiler in Ivy mode (internal only)

  Returns:
    the result of the ng_module rule as a dict, suitable for
    conversion by ts_providers_dict_to_struct
  """

  tsconfig = _ngc_tsconfig if not ivy else _ivy_tsconfig

  providers = ts_compile_actions(
      ctx, is_library=True, compile_action=_prodmode_compile_action,
      devmode_compile_action=_devmode_compile_action,
      tsc_wrapped_tsconfig=tsconfig,
      outputs = _ts_expected_outs)

  outs = _expected_outs(ctx)
  providers["angular"] = {
    "summaries": _expected_outs(ctx).summaries
  }
  providers["ngc_messages"] = outs.i18n_messages

  # Only produces the flattened "index bundle" metadata when requested by some other rule
  # and only under Bazel
  if hasattr(ctx.executable, "_index_bundler") and ctx.attr.module_name:
    bundle_index_metadata = [_write_bundle_index(ctx)]
  else:
    bundle_index_metadata = []

  providers["angular"]["flat_module_metadata"] = depset(bundle_index_metadata)

  return providers

def _ng_module_impl(ctx):
  return ts_providers_dict_to_struct(ng_module_impl(ctx, compile_ts))

def _ivy_module_impl(ctx):
  return ts_providers_dict_to_struct(ng_module_impl(ctx, compile_ts, True))

NG_MODULE_ATTRIBUTES = {
    "srcs": attr.label_list(allow_files = [".ts"]),

    "deps": attr.label_list(aspects = DEPS_ASPECTS + [_collect_summaries_aspect]),

    "assets": attr.label_list(allow_files = [
      ".css",
      # TODO(alexeagle): change this to ".ng.html" when usages updated
      ".html",
    ]),

    "factories": attr.label_list(
        allow_files = [".ts", ".html"],
        mandatory = False),

    "filter_summaries": attr.bool(default = False),

    "type_check": attr.bool(default = True),

    "inline_resources": attr.bool(default = True),

    "no_i18n": attr.bool(default = False),

    "compiler": attr.label(
        default = Label("//packages/bazel/src/ngc-wrapped"),
        executable = True,
        cfg = "host",
    ),

    "_ng_xi18n": attr.label(
        default = Label("//packages/bazel/src/ngc-wrapped:xi18n"),
        executable = True,
        cfg = "host",
    ),

    "_supports_workers": attr.bool(default = True),
}

NG_MODULE_RULE_ATTRS = dict(dict(COMMON_ATTRIBUTES, **NG_MODULE_ATTRIBUTES), **{
    "tsconfig": attr.label(allow_files = True, single_file = True),

    # @// is special syntax for the "main" repository
    # The default assumes the user specified a target "node_modules" in their
    # root BUILD file.
    "node_modules": attr.label(
        default = Label("@//:node_modules")
    ),

    "entry_point": attr.string(),

    # Default is %{name}_public_index
    # The suffix points to the generated "bundle index" files that users import from
    # The default is intended to avoid collisions with the users input files.
    # Later packaging rules will point to these generated files as the entry point
    # into the package.
    # See the flatModuleOutFile documentation in
    # https://github.com/angular/angular/blob/master/packages/compiler-cli/src/transformers/api.ts
    "flat_module_out_file": attr.string(),

    "_index_bundler": attr.label(
        executable = True,
        cfg = "host",
        default = Label("//packages/bazel/src:index_bundler")),
})

ng_module = rule(
    implementation = _ng_module_impl,
    attrs = NG_MODULE_RULE_ATTRS,
    outputs = COMMON_OUTPUTS,
)

# TODO(alxhub): this rule exists to allow early testing of the Ivy compiler within angular/angular,
# and should not be made public. When ng_module() supports Ivy-mode outputs, this rule should be
# removed and its usages refactored to use ng_module() directly.
internal_ivy_ng_module = rule(
    implementation = _ivy_module_impl,
    attrs = NG_MODULE_RULE_ATTRS,
    outputs = COMMON_OUTPUTS,
)
