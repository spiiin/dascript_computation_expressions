cmake_minimum_required(VERSION 3.20)
project(ce_task_aot LANGUAGES CXX)
find_package(DAS REQUIRED)
get_filename_component(DAS_SDK_ROOT "${DAS_DIR}/../../.." ABSOLUTE)
if(NOT SCRIPT_MANIFEST)
  message(FATAL_ERROR "Pass -DSCRIPT_MANIFEST=<file with absolute .das paths>")
endif()
file(STRINGS "${SCRIPT_MANIFEST}" scripts)
file(GLOB_RECURSE ce_dependencies CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/../packages/computation/*.das"
  "${CMAKE_CURRENT_SOURCE_DIR}/../packages/computation_task/*.das"
  "${CMAKE_CURRENT_SOURCE_DIR}/../examples/builders/*.das"
  "${CMAKE_CURRENT_SOURCE_DIR}/../support/*.das")
set(generated)
set(async_benchmark_aot OFF)
foreach(script IN LISTS scripts)
  get_filename_component(stem "${script}" NAME_WE)
  set(test_dependencies ${ce_dependencies})
  if(stem STREQUAL "test_async_sequence_benchmarks")
    set(async_benchmark_aot ON)
    list(APPEND test_dependencies "${CMAKE_CURRENT_SOURCE_DIR}/../benchmarks/async_sequence_workloads.das")
  endif()
  set(cpp "${CMAKE_CURRENT_BINARY_DIR}/generated/${stem}.cpp")
  file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/generated")
  add_custom_command(OUTPUT "${cpp}"
    COMMAND $<TARGET_FILE:DAS::daslang> -aot "${script}" "${cpp}"
    DEPENDS "${script}" ${test_dependencies} VERBATIM)
  list(APPEND generated "${cpp}")
endforeach()
if(async_benchmark_aot)
  set(script "${CMAKE_CURRENT_SOURCE_DIR}/../benchmarks/async_sequence_workloads.das")
  set(cpp "${CMAKE_CURRENT_BINARY_DIR}/generated/lib_async_sequence_workloads.cpp")
  add_custom_command(OUTPUT "${cpp}"
    COMMAND $<TARGET_FILE:DAS::daslang> -aotlib "${script}" "${cpp}"
    DEPENDS "${script}" ${ce_dependencies} VERBATIM)
  list(APPEND generated "${cpp}")
endif()
# Paths are relative to the repository root, without the extension.
foreach(module_path IN ITEMS
    packages/computation/builder_protocol
    packages/computation/computation_resources
    packages/computation/sequence_runtime
    packages/computation/zip_runtime
    packages/computation_task/cancellation_token
    packages/computation_task/task_builder
    packages/computation_task/task_delay
    packages/computation_task/task_combinators
    packages/computation_task/task_scheduler
    packages/computation_task/task_runtime
    packages/computation_task/task_channel
    packages/computation_task/task_parallel
    packages/computation_task/task_jobque
    packages/computation_task/task_events
    packages/computation/deferred_runtime
    packages/computation_task/async_sequence_builder
    packages/computation/computation_builders
    packages/computation/move_builders
    packages/computation/list_builder
    packages/computation/sequence_builder
    packages/computation/parser_builder
    packages/computation/search_builder
    examples/builders/query_builder)
  set(script "${CMAKE_CURRENT_SOURCE_DIR}/../${module_path}.das")
  get_filename_component(module "${module_path}" NAME)
  set(cpp "${CMAKE_CURRENT_BINARY_DIR}/generated/lib_${module}.cpp")
  add_custom_command(OUTPUT "${cpp}"
    COMMAND $<TARGET_FILE:DAS::daslang> -aotlib "${script}" "${cpp}"
    DEPENDS "${script}" ${ce_dependencies} VERBATIM)
  list(APPEND generated "${cpp}")
endforeach()
# Parser's integer conversion calls nongeneric standard-library functions.
foreach(module IN ITEMS strings_convert jobque_boost)
  set(script "${DAS_SDK_ROOT}/daslib/${module}.das")
  set(cpp "${CMAKE_CURRENT_BINARY_DIR}/generated/daslib_${module}.cpp")
  add_custom_command(OUTPUT "${cpp}"
    COMMAND $<TARGET_FILE:DAS::daslang> -aotlib "${script}" "${cpp}"
    DEPENDS "${script}" VERBATIM)
  list(APPEND generated "${cpp}")
endforeach()
add_executable(ce_task_aot main.cpp ${generated})
target_link_libraries(ce_task_aot PRIVATE DAS::libDaScriptDyn)
target_compile_definitions(ce_task_aot PRIVATE DAS_MOD_EXPORTS)
target_compile_features(ce_task_aot PRIVATE cxx_std_17)
if(MSVC)
  target_compile_options(ce_task_aot PRIVATE /bigobj /wd4005 "/FI${CMAKE_CURRENT_SOURCE_DIR}/recover_064.h")
else()
  target_compile_options(ce_task_aot PRIVATE -include "${CMAKE_CURRENT_SOURCE_DIR}/recover_064.h")
endif()
add_custom_command(TARGET ce_task_aot POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${DAS_SDK_ROOT}/bin/libDaScriptDyn.dll" "$<TARGET_FILE_DIR:ce_task_aot>"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${DAS_SDK_ROOT}/bin/libDaScriptDyn_runtime.dll" "$<TARGET_FILE_DIR:ce_task_aot>")
