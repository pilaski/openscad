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
#include "geometry/GeometryUtils.h"
#include "geometry/PolySet.h"
#include "geometry/PolySetUtils.h"
#include "geometry/linalg.h"
#include "io/export.h"

#include <vector>

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

// Shared front half of the pipeline: scad text -> evaluated geometry.
// Never returns null on success (an empty model yields an empty PolySet).
int evaluate_to_geometry(const std::string& text_in, const std::string& filename,
                         double fn_override, std::shared_ptr<const Geometry>& root_geom,
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
  root_geom = geomevaluator.evaluateGeometry(*tree.root(), allownef);
  if (!root_geom) root_geom = std::make_shared<PolySet>(3);
  return 0;
}

// Core pipeline: scad text -> geometry -> encoded bytes on `out`.
int render_to_stream(const std::string& text_in, const std::string& filename,
                     double fn_override, OSKFormat format, std::ostream& out,
                     std::string& err)
{
  std::shared_ptr<const Geometry> root_geom;
  int rc = evaluate_to_geometry(text_in, filename, fn_override, root_geom, err);
  if (rc != 0) return rc;

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

// Convert evaluated geometry into an indexed triangle mesh in the C ABI struct.
// On any failure the caller-supplied buffers are left null and `mesh` is zeroed.
int geometry_to_mesh(const std::shared_ptr<const Geometry>& geom, bool with_normals,
                     OSKMesh& mesh, std::string& err)
{
  mesh = OSKMesh{};

  std::shared_ptr<const PolySet> ps = PolySetUtils::getGeometryAsPolySet(geom);
  if (!ps || ps->vertices.empty()) return 0;  // empty model -> empty mesh

  std::unique_ptr<PolySet> tri = PolySetUtils::tessellate_faces(*ps);
  const PolySet& t = tri ? *tri : *ps;

  const size_t vcount = t.vertices.size();

  // Count emitted triangles (faces are triangles after tessellation; fan-split
  // defensively in case any non-triangular face slips through).
  size_t tcount = 0;
  for (const auto& f : t.indices) {
    if (f.size() >= 3) tcount += f.size() - 2;
  }
  if (vcount == 0 || tcount == 0) return 0;

  auto *positions = static_cast<float *>(std::malloc(sizeof(float) * 3 * vcount));
  auto *indices = static_cast<uint32_t *>(std::malloc(sizeof(uint32_t) * 3 * tcount));
  float *normals = with_normals
                     ? static_cast<float *>(std::malloc(sizeof(float) * 3 * vcount))
                     : nullptr;
  if (!positions || !indices || (with_normals && !normals)) {
    std::free(positions);
    std::free(indices);
    std::free(normals);
    err = "out of memory building mesh";
    return 3;
  }

  for (size_t i = 0; i < vcount; ++i) {
    const Vector3d& v = t.vertices[i];
    positions[3 * i + 0] = static_cast<float>(v.x());
    positions[3 * i + 1] = static_cast<float>(v.y());
    positions[3 * i + 2] = static_cast<float>(v.z());
  }

  std::vector<Vector3d> accum;
  if (with_normals) accum.assign(vcount, Vector3d::Zero());

  size_t ti = 0;
  for (const auto& f : t.indices) {
    if (f.size() < 3) continue;
    // Triangle fan around the first vertex of the face.
    for (size_t k = 1; k + 1 < f.size(); ++k) {
      const uint32_t a = static_cast<uint32_t>(f[0]);
      const uint32_t b = static_cast<uint32_t>(f[k]);
      const uint32_t c = static_cast<uint32_t>(f[k + 1]);
      indices[3 * ti + 0] = a;
      indices[3 * ti + 1] = b;
      indices[3 * ti + 2] = c;
      ++ti;
      if (with_normals) {
        // Unnormalized cross product == 2*area*normal, giving area weighting.
        const Vector3d n =
          (t.vertices[b] - t.vertices[a]).cross(t.vertices[c] - t.vertices[a]);
        accum[a] += n;
        accum[b] += n;
        accum[c] += n;
      }
    }
  }

  if (with_normals) {
    for (size_t i = 0; i < vcount; ++i) {
      Vector3d n = accum[i];
      const double len = n.norm();
      if (len > 1e-12) n /= len; else n = Vector3d(0, 0, 1);
      normals[3 * i + 0] = static_cast<float>(n.x());
      normals[3 * i + 1] = static_cast<float>(n.y());
      normals[3 * i + 2] = static_cast<float>(n.z());
    }
  }

  mesh.positions = positions;
  mesh.normals = normals;
  mesh.indices = indices;
  mesh.vertex_count = vcount;
  mesh.triangle_count = ti;
  return 0;
}

}  // namespace

extern "C" {

void osk_init(const char *application_path)
{
  std::call_once(g_init_flag, [application_path] {
    // Note: do NOT call PlatformUtils::applicationPath() here — it is only valid
    // after registerApplicationPath(). Fall back to the current directory.
    std::string appPath = application_path ? std::string(application_path) : std::string();
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

int osk_render_mesh(const char *scad_source, const char *search_path,
                    double fn_override, int with_normals,
                    OSKMesh *out_mesh, char **error_out)
{
  (void)search_path;  // reserved for use/include resolution; <string> uses CWD for now
  if (!scad_source || !out_mesh) {
    set_error(error_out, "null argument");
    return 2;
  }
  *out_mesh = OSKMesh{};

  std::lock_guard<std::mutex> lock(g_render_mutex);
  osk_init(nullptr);

  std::string err;
  int rc;
  try {
    std::shared_ptr<const Geometry> root_geom;
    rc = evaluate_to_geometry(scad_source, "<string>.scad", fn_override, root_geom, err);
    if (rc == 0) rc = geometry_to_mesh(root_geom, with_normals != 0, *out_mesh, err);
  } catch (const std::exception& e) {
    err = std::string("exception: ") + e.what();
    rc = 1;
  } catch (...) {
    err = "unknown exception during render";
    rc = 1;
  }
  if (rc != 0) {
    osk_mesh_free(out_mesh);
    set_error(error_out, err);
    return rc;
  }
  return 0;
}

void osk_mesh_free(OSKMesh *mesh)
{
  if (!mesh) return;
  std::free(mesh->positions);
  std::free(mesh->normals);
  std::free(mesh->indices);
  *mesh = OSKMesh{};
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
