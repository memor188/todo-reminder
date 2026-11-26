/// Thanos-snap 式消散效果（GPU fragment shader，不是 CPU 粒子）。
///
/// 源码来自 github.com/yunusemrealpak/disintegrate（MIT，见同目录 LICENSE），
/// 2026-11-26 抠进项目本地：该库未发布 pub.dev、star 极少，依赖它不稳定；
/// 抠进来只有 3 个文件、零第三方依赖，完全自主可控。
///
/// 唯一改动：[DisintegrateProgram] 里的 shader asset 路径从
/// `packages/disintegrate/shaders/disintegrate.frag` 改为项目本地的
/// `shaders/disintegrate.frag`。
library;

export 'disintegrate.dart' show Disintegrate, DisintegrateEffect;
export 'disintegrate_program.dart' show DisintegrateProgram;
