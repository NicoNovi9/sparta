// Kokkos Tools library that logs every large allocation the moment it happens.
//
// The memory tools in kokkos-tools report at finalize, which never comes when
// a run aborts on Kokkos::Experimental::BadAlloc. This one writes each large
// event to stderr immediately, together with the bytes then live in that
// memory space, so the allocation that fills the GPU is on record before the
// process dies.
//
// Build (login node):  nicola/tools/build_kp_big_alloc.sh
// Use:                 KOKKOS_TOOLS_LIBS=/path/to/kp_big_alloc.so
//                      KP_BIG_ALLOC_MB=100   (optional threshold, default 100)
//
// Only allocations made through Kokkos are seen. If the GPU fills up and
// nothing is logged, the memory was taken outside Kokkos (MPI, CUDA runtime).

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
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
std::chrono::steady_clock::time_point t0;
std::unordered_map<const void*, uint64_t> live;   // pointer -> bytes
std::map<std::string, double> live_mb;             // space -> MB live
double peak_mb = 0.0;

double elapsed() {
  return std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
}

}  // namespace

extern "C" void kokkosp_init_library(const int, const uint64_t, const uint32_t,
                                     Kokkos_Profiling_KokkosPDeviceInfo*) {
  if (const char* s = std::getenv("KP_BIG_ALLOC_MB")) threshold_mb = std::atof(s);
  t0 = std::chrono::steady_clock::now();
  std::fprintf(stderr, "[kp] logging allocations >= %.0f MB\n", threshold_mb);
  std::fflush(stderr);
}

extern "C" void kokkosp_finalize_library() {
  std::fprintf(stderr, "[kp] finalize, peak live in any space %.1f MB\n", peak_mb);
  std::fflush(stderr);
}

extern "C" void kokkosp_allocate_data(const Kokkos_Profiling_SpaceHandle space,
                                      const char* label, const void* ptr,
                                      const uint64_t size) {
  std::lock_guard<std::mutex> lock(mtx);
  const double mb = size / 1048576.0;
  live[ptr] = size;
  double& total = live_mb[space.name];
  total += mb;
  if (total > peak_mb) peak_mb = total;
  if (mb >= threshold_mb) {
    std::fprintf(stderr, "[kp] %9.2fs  alloc   %10.1f MB  %-8s live %10.1f MB  \"%s\"\n",
                 elapsed(), mb, space.name, total, label);
    std::fflush(stderr);
  }
}

extern "C" void kokkosp_deallocate_data(const Kokkos_Profiling_SpaceHandle space,
                                        const char* label, const void* ptr,
                                        const uint64_t size) {
  std::lock_guard<std::mutex> lock(mtx);
  const double mb = size / 1048576.0;
  live.erase(ptr);
  double& total = live_mb[space.name];
  total -= mb;
  if (mb >= threshold_mb) {
    std::fprintf(stderr, "[kp] %9.2fs  dealloc %10.1f MB  %-8s live %10.1f MB  \"%s\"\n",
                 elapsed(), mb, space.name, total, label);
    std::fflush(stderr);
  }
}
