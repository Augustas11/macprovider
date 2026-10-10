# Lab-only on top of the core fix: counters for live caches, live keys and
# entries the cross-thread erase removed from threads other than the caller.
import sys
p = sys.argv[1] + '/Source/Cmlx/mlx/mlx/compile.cpp'
s = open(p).read()
def rep(old, new):
    global s
    assert s.count(old) == 1, old[:60]
    s = s.replace(old, new)
rep('''  void erase(std::uintptr_t fun_id) {
    std::unique_lock lock(mutex_);
    cache_.erase(fun_id);
  }''', '''  size_t erase(std::uintptr_t fun_id) {
    std::unique_lock lock(mutex_);
    return cache_.erase(fun_id);
  }

  size_t lab_size() {
    std::shared_lock lock(mutex_);
    return cache_.size();
  }''')
rep('''  for (auto& p : caches) {
    p->erase(fun_id);
  }
}''', '''  auto* self = compile_cache_unsafe().get();
  for (auto& p : caches) {
    auto n = p->erase(fun_id);
    if (p.get() != self) {
      lab_foreign_erased() += n;
    }
  }
}

} // namespace detail
} // namespace mlx::core

extern "C" void mlx_lab_compile_cache_stats(uint64_t* out) {
  using namespace mlx::core::detail;
  std::vector<std::shared_ptr<CompileCache>> caches;
  {
    auto& registry = compile_cache_registry();
    std::lock_guard lock(registry.mutex);
    for (auto& c : registry.caches) {
      if (auto p = c.lock()) {
        caches.push_back(std::move(p));
      }
    }
  }
  uint64_t keys = 0;
  for (auto& p : caches) {
    keys += p->lab_size();
  }
  out[0] = caches.size();
  out[1] = keys;
  out[2] = lab_foreign_erased().load();
}

namespace mlx::core {
namespace detail {''')
rep('''CompileCacheRegistry& compile_cache_registry() {''', '''std::atomic<uint64_t>& lab_foreign_erased() {
  static std::atomic<uint64_t> n{0};
  return n;
}

CompileCacheRegistry& compile_cache_registry() {''')
open(p, 'w').write(s)
print("patched core lab", p)

p = sys.argv[1] + '/Source/MLX/Transforms+Compile.swift'
s = open(p).read()
rep('''    /// One line for lab logs.
    public static func summary() -> String {
        lock.withLock {
            "stale_hits=''', '''    /// One line for lab logs.
    public static func summary() -> String {
        var core = [UInt64](repeating: 0, count: 3)
        labCompileCacheStats(&core)
        return lock.withLock {
            "core_caches=\\(core[0]) core_keys=\\(core[1]) core_foreign_erased=\\(core[2]) "
                + "stale_hits=''')
s += '''
@_silgen_name("mlx_lab_compile_cache_stats")
private func labCompileCacheStats(_ out: UnsafeMutablePointer<UInt64>)
'''
open(p, 'w').write(s)
print("patched swift lab", p)
