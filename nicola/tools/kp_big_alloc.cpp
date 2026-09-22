// Kokkos Tools library for the H200 BadAlloc investigation.
//
// 1. Logs every Kokkos allocation/deallocation >= KP_BIG_ALLOC_MB (default
//    100) the moment it happens, with the bytes live in that memory space.
// 2. Watches the device memory the driver reports free (cuMemGetInfo) at
//    every Kokkos event: kernel begin/end, fence begin/end, deep copy,
//    allocation. When it moves by more than KP_MEMWATCH_GB (default 1), it
//    prints the change together with the last events, so memory taken
//    outside Kokkos (driver, runtime, libraries) is tied to what was running.
//
// Everything is written to stderr and flushed immediately: the run of
// interest aborts, so nothing can wait for finalize.
//
// The CUDA driver is looked up at run time in the process (SPARTA has
// already loaded it), so this builds with plain g++ and no CUDA toolkit:
//   nicola/tools/build_kp_big_alloc.sh
// Use:  KOKKOS_TOOLS_LIBS=/path/to/kp_big_alloc.so

#include <dlfcn.h>

#include <chrono>
#include <cmath>
#include <ctime>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <mutex>
#include <string>
#include <unordered_map>

struct Kokkos_Profiling_KokkosPDeviceInfo {
  size_t deviceID;
};

struct Kokkos_Profiling_SpaceHandle {
  char name[64];
};

namespace {

std::mutex mtx;
double threshold_mb = 100.0;
double watch_gb = 1.0;
std::chrono::steady_clock::time_point t0;
std::map<std::string, double> live_mb;   // space -> MB live through Kokkos
double peak_mb = 0.0;

// --- device free memory, through the driver already loaded in the process
using MemGetInfo = int (*)(size_t*, size_t*);   // CUresult cuMemGetInfo_v2
MemGetInfo mem_get_info = nullptr;
bool lookup_done = false;
double last_free_gb = -1.0;

// --- recent events, printed when free memory jumps
const int NRECENT = 12;
std::string recent[NRECENT];
int nrecent = 0;

// kernel/fence ids handed back to Kokkos -> their names
uint64_t next_id = 0;
std::unordered_map<uint64_t, std::string> open_regions;

double elapsed() {
  return std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
}

// wall-clock time of day, to line events up with nvidia-smi samples
std::string clock_now() {
  auto now = std::chrono::system_clock::now();
  std::time_t tt = std::chrono::system_clock::to_time_t(now);
  int ms = int(std::chrono::duration_cast<std::chrono::milliseconds>(
                   now.time_since_epoch()).count() % 1000);
  std::tm tmv;
  localtime_r(&tt, &tmv);
  char buf[32];
  std::snprintf(buf, sizeof(buf), "%02d:%02d:%02d.%03d", tmv.tm_hour, tmv.tm_min,
                tmv.tm_sec, ms);
  return buf;
}

bool device_free_gb(double& free_gb) {
  if (!lookup_done) {
    lookup_done = true;
    void* h = dlopen("libcuda.so.1", RTLD_NOW | RTLD_NOLOAD);
    if (!h) h = dlopen("libcuda.so.1", RTLD_NOW);
    if (h) mem_get_info = reinterpret_cast<MemGetInfo>(dlsym(h, "cuMemGetInfo_v2"));
    std::fprintf(stderr, "[kp] memory watch %s\n",
                 mem_get_info ? "enabled" : "UNAVAILABLE (cuMemGetInfo not found)");
  }
  if (!mem_get_info) return false;
  size_t fr = 0, tot = 0;
  if (mem_get_info(&fr, &tot) != 0) return false;   // no current context yet
  free_gb = fr / 1073741824.0;
  return true;
}

// Record an event; print it with the recent history if free memory jumped.
void event(const std::string& what) {
  char line[400];
  std::snprintf(line, sizeof(line), "%9.3fs  %s", elapsed(), what.c_str());
  recent[nrecent % NRECENT] = line;
  nrecent++;

  double free_gb;
  if (!device_free_gb(free_gb)) return;
  if (last_free_gb < 0.0) {
    std::fprintf(stderr, "[kp] %9.3fs  %s  device free %.1f GB at start of watch\n",
                 elapsed(), clock_now().c_str(), free_gb);
    last_free_gb = free_gb;
    return;
  }
  if (std::fabs(free_gb - last_free_gb) < watch_gb) return;

  std::fprintf(stderr, "[kp] ==== %s  device free %.1f GB -> %.1f GB, recent events:\n",
               clock_now().c_str(), last_free_gb, free_gb);
  int first = nrecent > NRECENT ? nrecent - NRECENT : 0;
  for (int i = first; i < nrecent; i++)
    std::fprintf(stderr, "[kp]      %s\n", recent[i % NRECENT].c_str());
  std::fflush(stderr);
  last_free_gb = free_gb;
}

void begin_region(const char* kind, const char* name, uint64_t* id) {
  std::lock_guard<std::mutex> lock(mtx);
  *id = ++next_id;
  std::string s = std::string(kind) + " \"" + name + "\"";
  open_regions[*id] = s;
  event("begin " + s);
}

void end_region(uint64_t id) {
  std::lock_guard<std::mutex> lock(mtx);
  auto it = open_regions.find(id);
  std::string s = it != open_regions.end() ? it->second : "?";
  if (it != open_regions.end()) open_regions.erase(it);
  event("end   " + s);
}

}  // namespace

extern "C" void kokkosp_init_library(const int, const uint64_t, const uint32_t,
                                     Kokkos_Profiling_KokkosPDeviceInfo*) {
  if (const char* s = std::getenv("KP_BIG_ALLOC_MB")) threshold_mb = std::atof(s);
  if (const char* s = std::getenv("KP_MEMWATCH_GB")) watch_gb = std::atof(s);
  t0 = std::chrono::steady_clock::now();
  std::fprintf(stderr, "[kp] logging allocations >= %.0f MB, "
               "watching device free memory for jumps >= %.1f GB\n",
               threshold_mb, watch_gb);
  std::fflush(stderr);
}

extern "C" void kokkosp_finalize_library() {
  std::fprintf(stderr, "[kp] finalize, peak live in any space %.1f MB\n", peak_mb);
  std::fflush(stderr);
}

extern "C" void kokkosp_begin_parallel_for(const char* name, const uint32_t, uint64_t* id) {
  begin_region("for", name, id);
}
extern "C" void kokkosp_end_parallel_for(const uint64_t id) { end_region(id); }

extern "C" void kokkosp_begin_parallel_reduce(const char* name, const uint32_t, uint64_t* id) {
  begin_region("reduce", name, id);
}
extern "C" void kokkosp_end_parallel_reduce(const uint64_t id) { end_region(id); }

extern "C" void kokkosp_begin_parallel_scan(const char* name, const uint32_t, uint64_t* id) {
  begin_region("scan", name, id);
}
extern "C" void kokkosp_end_parallel_scan(const uint64_t id) { end_region(id); }

extern "C" void kokkosp_begin_fence(const char* name, const uint32_t, uint64_t* id) {
  begin_region("fence", name, id);
}
extern "C" void kokkosp_end_fence(const uint64_t id) { end_region(id); }

extern "C" void kokkosp_begin_deep_copy(Kokkos_Profiling_SpaceHandle dst_space,
                                        const char* dst_label, const void*,
                                        Kokkos_Profiling_SpaceHandle src_space,
                                        const char* src_label, const void*,
                                        uint64_t size) {
  std::lock_guard<std::mutex> lock(mtx);
  char s[300];
  std::snprintf(s, sizeof(s), "deep_copy %.1f MB %s \"%s\" <- %s \"%s\"",
                size / 1048576.0, dst_space.name, dst_label, src_space.name, src_label);
  event(s);
}
extern "C" void kokkosp_end_deep_copy() {
  std::lock_guard<std::mutex> lock(mtx);
  event("end   deep_copy");
}

extern "C" void kokkosp_allocate_data(const Kokkos_Profiling_SpaceHandle space,
                                      const char* label, const void*,
                                      const uint64_t size) {
  std::lock_guard<std::mutex> lock(mtx);
  const double mb = size / 1048576.0;
  double& total = live_mb[space.name];
  total += mb;
  if (total > peak_mb) peak_mb = total;
  if (mb >= threshold_mb) {
    std::fprintf(stderr, "[kp] %9.3fs  alloc   %10.1f MB  %-8s live %10.1f MB  \"%s\"\n",
                 elapsed(), mb, space.name, total, label);
    std::fflush(stderr);
  }
  char s[200];
  std::snprintf(s, sizeof(s), "alloc %.1f MB %s \"%s\"", mb, space.name, label);
  event(s);
}

extern "C" void kokkosp_deallocate_data(const Kokkos_Profiling_SpaceHandle space,
                                        const char* label, const void*,
                                        const uint64_t size) {
  std::lock_guard<std::mutex> lock(mtx);
  const double mb = size / 1048576.0;
  double& total = live_mb[space.name];
  total -= mb;
  if (mb >= threshold_mb) {
    std::fprintf(stderr, "[kp] %9.3fs  dealloc %10.1f MB  %-8s live %10.1f MB  \"%s\"\n",
                 elapsed(), mb, space.name, total, label);
    std::fflush(stderr);
  }
  char s[200];
  std::snprintf(s, sizeof(s), "dealloc %.1f MB %s \"%s\"", mb, space.name, label);
  event(s);
}
