/*
 * openscad_kernel.cpp — implementation of the pure-C ABI over the real OpenSCAD
 * headless geometry kernel. Mirrors the evaluate/export pipeline of
 * src/openscad.cc::do_export(), minus the CommandLine / program_options /
 * camera / preview machinery.
 */
#include "openscad_kernel.h"

#include "openscad.h"                 // parse(), localization_init(), commandline_commands
#include "platform/PlatformUtils.h"   // registerApplicationPath(), applicationPath()
#include "core/Builtins.h"            // Builtins::initialize()
#include "core/parsersettings.h"      // parser_init()
#include "core/SourceFile.h"
#include "core/node.h"                // AbstractNode, find_root_tag()
#include "core/Tree.h"
#include "core/BuiltinContext.h"
#include "core/Context.h"
#include "core/EvaluationSession.h"
#include "geometry/Geometry.h"
#include "geometry/GeometryEvaluator.h"
#include "geometry/PolySet.h"
#include "io/export.h"

#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <mutex>
#include <sstream>
#include <string>

namespace fs = std::filesystem;

namespace {

std::once_flag g_init_flag;
std::mutex g_render_mutex;

char *dup_cstr(const std::string& s)
{
  char *p = static_cast<char *>(std::malloc(s.size() + 1));
  if (p) std::memcpy(p, s.c_str(), s.size() + 1);
  return p;
}

void set_error(char **error_out, const std::string& msg)
{
  if (error_out) *error_out = dup_cstr(msg.empty() ? "render failed" : msg);
}

// Core pipeline: scad text -> geometry -> encoded bytes on `out`.
int render_to_stream(const std::string& text_in, const std::string& filename,
                     double fn_override, OSKFormat format, std::ostream& out,
                     std::string& err)
{
  std::string text;
  if (fn_override > 0) {
    std::ostringstream pre;
    pre << "$fn=" << fn_override << ";\n";
    text = pre.str();
  }
  text += text_in;
  // OpenSCAD command-line convention: ETX sentinel then any -D commandline defines.
  text += "\n\x03\n" + commandline_commands;

  SourceFile *root_file = nullptr;
  if (!parse(root_file, text, filename, filename, false) || !root_file) {
    delete root_file;
    err = "parse error in OpenSCAD source";
    return 1;
  }
  std::unique_ptr<SourceFile> root_file_guard(root_file);

  fs::path fpath = filename.empty() ? fs::current_path() : fs::absolute(fs::path(filename));
  fs::path fparent = fpath.parent_path();
  if (fparent.empty()) fparent = fs::current_path();

  root_file->handleDependencies();

  EvaluationSession session{fparent.string()};
  ContextHandle<BuiltinContext> builtin_context{Context::create<BuiltinContext>(&session)};

  AbstractNode::resetIndexCounter();
  std::shared_ptr<const FileContext> file_context;
  std::shared_ptr<AbstractNode> absolute_root_node =
    root_file->instantiate(*builtin_context, &file_context);
  if (!absolute_root_node) {
    err = "failed to instantiate model";
    return 1;
  }

  std::shared_ptr<const AbstractNode> root_node;
  const Location *nextLocation = nullptr;
  if (!(root_node = find_root_tag(absolute_root_node, &nextLocation))) {
    root_node = absolute_root_node;
  }

  Tree tree(root_node, fparent.string());
  GeometryEvaluator geomevaluator(tree);
  constexpr bool allownef = true;
  std::shared_ptr<const Geometry> root_geom = geomevaluator.evaluateGeometry(*tree.root(), allownef);
  if (!root_geom) root_geom = std::make_shared<PolySet>(3);

  switch (format) {
    case OSK_FORMAT_BINSTL:   export_stl(root_geom, out, true);  break;
    case OSK_FORMAT_ASCIISTL: export_stl(root_geom, out, false); break;
    case OSK_FORMAT_OFF:      export_off(root_geom, out);        break;
    case OSK_FORMAT_OBJ:      export_obj(root_geom, out);        break;
    case OSK_FORMAT_3MF: {
      ExportInfo ei = createExportInfo(FileFormat::_3MF, fileformat::info(FileFormat::_3MF),
                                       filename, nullptr, {});
      export_3mf(root_geom, out, ei);
      break;
    }
    default:
      err = "unsupported output format";
      return 1;
  }
  return 0;
}

}  // namespace

extern "C" {

void osk_init(const char *application_path)
{
  std::call_once(g_init_flag, [application_path] {
    std::string appPath = application_path ? std::string(application_path) : PlatformUtils::applicationPath();
    if (appPath.empty()) appPath = fs::current_path().string();
    PlatformUtils::registerApplicationPath(appPath);
    Builtins::initialize();
    parser_init();
    localization_init();
  });
}

const char *osk_backend(void)
{
  return "OpenSCAD (CGAL + Manifold)";
}

int osk_render_string(const char *scad_source, OSKFormat format,
                      const char *search_path, double fn_override,
                      uint8_t **out_buffer, size_t *out_len, char **error_out)
{
  (void)search_path;  // reserved for use/include resolution; <string> uses CWD for now
  if (!scad_source || !out_buffer || !out_len) {
    set_error(error_out, "null argument");
    return 2;
  }
  std::lock_guard<std::mutex> lock(g_render_mutex);
  osk_init(nullptr);

  std::ostringstream oss(std::ios::out | std::ios::binary);
  std::string err;
  int rc;
  try {
    rc = render_to_stream(scad_source, "<string>.scad", fn_override, format, oss, err);
  } catch (const std::exception& e) {
    err = std::string("exception: ") + e.what();
    rc = 1;
  } catch (...) {
    err = "unknown exception during render";
    rc = 1;
  }
  if (rc != 0) {
    set_error(error_out, err);
    return rc;
  }

  std::string data = oss.str();
  uint8_t *buf = static_cast<uint8_t *>(std::malloc(data.size() ? data.size() : 1));
  if (!buf) {
    set_error(error_out, "out of memory");
    return 3;
  }
  if (!data.empty()) std::memcpy(buf, data.data(), data.size());
  *out_buffer = buf;
  *out_len = data.size();
  return 0;
}

int osk_render_file(const char *input_path, const char *output_path, int format,
                    double fn_override, char **error_out)
{
  if (!input_path || !output_path) {
    set_error(error_out, "null path");
    return 2;
  }
  std::lock_guard<std::mutex> lock(g_render_mutex);
  osk_init(nullptr);

  std::ifstream ifs(input_path, std::ios::binary);
  if (!ifs.is_open()) {
    set_error(error_out, std::string("cannot open input file: ") + input_path);
    return 1;
  }
  std::string text((std::istreambuf_iterator<char>(ifs)), std::istreambuf_iterator<char>());

  OSKFormat fmt;
  if (format < 0) {
    std::string ext = fs::path(output_path).extension().string();
    for (auto& c : ext) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    if (ext == ".stl") fmt = OSK_FORMAT_BINSTL;
    else if (ext == ".off") fmt = OSK_FORMAT_OFF;
    else if (ext == ".obj") fmt = OSK_FORMAT_OBJ;
    else if (ext == ".3mf") fmt = OSK_FORMAT_3MF;
    else {
      set_error(error_out, "cannot infer output format from extension");
      return 1;
    }
  } else {
    fmt = static_cast<OSKFormat>(format);
  }

  std::ofstream ofs(output_path, std::ios::binary);
  if (!ofs.is_open()) {
    set_error(error_out, std::string("cannot open output file: ") + output_path);
    return 1;
  }

  std::string err;
  int rc;
  try {
    rc = render_to_stream(text, input_path, fn_override, fmt, ofs, err);
  } catch (const std::exception& e) {
    err = std::string("exception: ") + e.what();
    rc = 1;
  } catch (...) {
    err = "unknown exception during render";
    rc = 1;
  }
  if (rc != 0) {
    set_error(error_out, err);
    return rc;
  }
  return 0;
}

void osk_buffer_free(uint8_t *buffer) { std::free(buffer); }
void osk_string_free(char *s) { std::free(s); }

}  // extern "C"
