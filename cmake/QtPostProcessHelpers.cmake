function(qt_internal_write_depends_file module)
    set(outfile "${QT_BUILD_DIR}/include/${module}/${module}Depends")
    set(contents "/* This file was generated by cmake with the info from ${module} target. */\n")
    string(APPEND contents "#ifdef __cplusplus /* create empty PCH in C mode */\n")
    foreach (m ${ARGN})
        string(APPEND contents "#  include <Qt${m}/Qt${m}>\n")
    endforeach()
    string(APPEND contents "#endif\n")

    file(GENERATE OUTPUT "${outfile}" CONTENT "${contents}")
endfunction()

macro(qt_collect_third_party_deps target)
    set(_target_is_static OFF)
    get_target_property(_target_type ${target} TYPE)
    if (${_target_type} STREQUAL "STATIC_LIBRARY")
        set(_target_is_static ON)
    endif()
    unset(_target_type)
    # If we are doing a non-static Qt build, we only want to propagate public dependencies.
    # If we are doing a static Qt build, we need to propagate all dependencies.
    set(depends_var "public_depends")
    if(_target_is_static)
        set(depends_var "depends")
    endif()
    unset(_target_is_static)

    foreach(dep ${${depends_var}} ${optional_public_depends})
        # Gather third party packages that should be found when using the Qt module.
        # Also handle nolink target dependencies.
        string(REGEX REPLACE "_nolink$" "" base_dep "${dep}")
        if(NOT base_dep STREQUAL dep)
            # Resets target name like Vulkan_nolink to Vulkan, because we need to call
            # find_package(Vulkan).
            set(dep ${base_dep})
        endif()

        # Strip any directory scope tokens.
        qt_internal_strip_target_directory_scope_token("${dep}" dep)
        if(TARGET ${dep})
            list(FIND third_party_deps_seen ${dep} dep_seen)

            get_target_property(package_name ${dep} INTERFACE_QT_PACKAGE_NAME)
            if(dep_seen EQUAL -1 AND package_name)
                list(APPEND third_party_deps_seen ${dep})
                get_target_property(package_is_optional ${dep} INTERFACE_QT_PACKAGE_IS_OPTIONAL)
                if(NOT package_is_optional AND dep IN_LIST optional_public_depends)
                    set(package_is_optional TRUE)
                endif()
                get_target_property(package_version ${dep} INTERFACE_QT_PACKAGE_VERSION)
                if(NOT package_version)
                    set(package_version "")
                endif()

                get_target_property(package_components ${dep} INTERFACE_QT_PACKAGE_COMPONENTS)
                if(NOT package_components)
                    set(package_components "")
                endif()

                list(APPEND third_party_deps
                    "${package_name}\;${package_is_optional}\;${package_version}\;${package_components}")
            endif()
        endif()
    endforeach()
endmacro()

function(qt_internal_create_module_depends_file target)
    get_target_property(target_type "${target}" TYPE)
    if(target_type STREQUAL "INTERFACE_LIBRARY")
        set(arg_HEADER_MODULE ON)
    else()
        set(arg_HEADER_MODULE OFF)
    endif()

    set(depends "")
    if(target_type STREQUAL "STATIC_LIBRARY" AND NOT arg_HEADER_MODULE)
        get_target_property(depends "${target}" LINK_LIBRARIES)
    endif()

    get_target_property(public_depends "${target}" INTERFACE_LINK_LIBRARIES)

    unset(optional_public_depends)
    if(TARGET "${target}Private")
        get_target_property(optional_public_depends "${target}Private" INTERFACE_LINK_LIBRARIES)
    endif()

    # Used for collecting Qt module dependencies that should be find_package()'d in
    # ModuleDependencies.cmake.
    get_target_property(target_deps "${target}" _qt_target_deps)
    set(target_deps_seen "")
    set(qt_module_dependencies "")

    if(NOT arg_HEADER_MODULE)
        get_target_property(extra_depends "${target}" QT_EXTRA_PACKAGE_DEPENDENCIES)
    endif()
    if(NOT extra_depends STREQUAL "${extra_depends}-NOTFOUND")
        list(APPEND target_deps "${extra_depends}")
    endif()

    # Used for assembling the content of an include/Module/ModuleDepends.h header.
    set(qtdeps "")

    # Used for collecting third party dependencies that should be find_package()'d in
    # ModuleDependencies.cmake.
    set(third_party_deps "")
    set(third_party_deps_seen "")

    # Used for collecting Qt tool dependencies that should be find_package()'d in
    # ModuleToolsDependencies.cmake.
    set(tool_deps "")
    set(tool_deps_seen "")

    # Used for collecting Qt tool dependencies that should be find_package()'d in
    # ModuleDependencies.cmake.
    set(main_module_tool_deps "")

    # Extra QtFooModuleTools packages to be added as dependencies to
    # QtModuleDependencies.cmake. Needed for QtWaylandCompositor / QtWaylandClient.
    if(NOT arg_HEADER_MODULE)
        get_target_property(extra_tools_package_dependencies "${target}"
                            QT_EXTRA_TOOLS_PACKAGE_DEPENDENCIES)
        if(extra_tools_package_dependencies)
            list(APPEND main_module_tool_deps "${extra_tools_package_dependencies}")
        endif()
    endif()

    qt_internal_get_qt_all_known_modules(known_modules)

    set(all_depends ${depends} ${public_depends})
    foreach (dep ${all_depends})
        # Normalize module by stripping leading "Qt::" and trailing "Private"
        if (dep MATCHES "Qt::([A-Za-z0-9]+)")
            set(dep "${CMAKE_MATCH_1}")
            if (TARGET Qt::${dep})
                get_target_property(dep_type Qt::${dep} TYPE)
                if (NOT dep_type STREQUAL "INTERFACE_LIBRARY")
                    get_target_property(skip_module_depends_include Qt::${dep} QT_MODULE_SKIP_DEPENDS_INCLUDE)
                    if (skip_module_depends_include)
                        continue()
                    endif()
                else()
                    get_target_property(module_has_headers Qt::${dep} INTERFACE_MODULE_HAS_HEADERS)
                    if (NOT module_has_headers)
                        continue()
                    endif()
                endif()
            endif()
        endif()
        if (dep MATCHES "(.*)Private")
            set(dep "${CMAKE_MATCH_1}")
        endif()

        list(FIND known_modules "${dep}" _pos)
        if (_pos GREATER -1)
            list(APPEND qtdeps "${dep}")

            # Make the ModuleTool package depend on dep's ModuleTool package.
            list(FIND tool_deps_seen ${dep} dep_seen)
            if(dep_seen EQUAL -1 AND ${dep} IN_LIST QT_KNOWN_MODULES_WITH_TOOLS)
                list(APPEND tool_deps_seen ${dep})
                list(APPEND tool_deps
                            "${INSTALL_CMAKE_NAMESPACE}${dep}Tools\;${PROJECT_VERSION}")
            endif()
        endif()
    endforeach()

    qt_collect_third_party_deps(${target})

    # Add dependency to the main ModuleTool package to ModuleDependencies file.
    if(${target} IN_LIST QT_KNOWN_MODULES_WITH_TOOLS)
        list(APPEND main_module_tool_deps
            "${INSTALL_CMAKE_NAMESPACE}${target}Tools\;${PROJECT_VERSION}")
    endif()

    # Dirty deduplication hack because of https://gitlab.kitware.com/cmake/cmake/issues/19200
    foreach(dep ${target_deps})
        if(dep)
            list(FIND target_deps_seen "${dep}" dep_seen)
            if(dep_seen EQUAL -1)
                list(LENGTH dep len)
                if(NOT (len EQUAL 2))
                    message(FATAL_ERROR "List '${dep}' should look like QtFoo;version")
                endif()
                list(GET dep 0 dep_name)
                list(GET dep 1 dep_ver)

                # Skip over Qt6 dependency, because we will manually handle it in the Dependencies
                # file before everything else, to ensure that find_package(Qt6Core)-style works.
                if(dep_name STREQUAL INSTALL_CMAKE_NAMESPACE)
                    continue()
                endif()

                list(APPEND target_deps_seen "${dep_name}\;${dep_ver}")

                if (dep_name MATCHES "${INSTALL_CMAKE_NAMESPACE}(.*)")
                    list(APPEND qt_module_dependencies "${CMAKE_MATCH_1}")
                endif()
            endif()
        endif()
    endforeach()
    set(target_deps "${target_deps_seen}")

    if (DEFINED qtdeps)
        list(REMOVE_DUPLICATES qtdeps)
    endif()

    get_target_property(hasModuleHeaders "${target}" INTERFACE_MODULE_HAS_HEADERS)
    if (${hasModuleHeaders})
        get_target_property(module_include_name "${target}" INTERFACE_MODULE_INCLUDE_NAME)
        qt_internal_write_depends_file(${module_include_name} ${qtdeps})
    endif()

    if(third_party_deps OR main_module_tool_deps OR target_deps)
        set(path_suffix "${INSTALL_CMAKE_NAMESPACE}${target}")
        qt_path_join(config_build_dir ${QT_CONFIG_BUILD_DIR} ${path_suffix})
        qt_path_join(config_install_dir ${QT_CONFIG_INSTALL_DIR} ${path_suffix})

        # Configure and install ModuleDependencies file.
        configure_file(
            "${QT_CMAKE_DIR}/QtModuleDependencies.cmake.in"
            "${config_build_dir}/${INSTALL_CMAKE_NAMESPACE}${target}Dependencies.cmake"
            @ONLY
        )

        qt_install(FILES
            "${config_build_dir}/${INSTALL_CMAKE_NAMESPACE}${target}Dependencies.cmake"
            DESTINATION "${config_install_dir}"
            COMPONENT Devel
        )

    endif()
    if(tool_deps)
        # The value of the property will be used by qt_export_tools.
        set_property(TARGET "${target}" PROPERTY _qt_tools_package_deps "${tool_deps}")
    endif()
endfunction()

function(qt_internal_create_plugin_depends_file target)
    get_target_property(plugin_install_package_suffix "${target}" _qt_plugin_install_package_suffix)
    get_target_property(depends "${target}" LINK_LIBRARIES)
    get_target_property(public_depends "${target}" INTERFACE_LINK_LIBRARIES)
    get_target_property(target_deps "${target}" _qt_target_deps)
    unset(optional_public_depends)
    set(target_deps_seen "")

    qt_collect_third_party_deps(${target})

    # Dirty hack because https://gitlab.kitware.com/cmake/cmake/issues/19200
    foreach(dep ${target_deps})
        if(dep)
            list(FIND target_deps_seen "${dep}" dep_seen)
            if(dep_seen EQUAL -1)
                list(LENGTH dep len)
                if(NOT (len EQUAL 2))
                    message(FATAL_ERROR "List '${dep}' should look like QtFoo;version")
                endif()
                list(GET dep 0 dep_name)
                list(GET dep 1 dep_ver)

                list(APPEND target_deps_seen "${dep_name}\;${dep_ver}")
            endif()
        endif()
    endforeach()
    set(target_deps "${target_deps_seen}")

    if(third_party_deps OR target_deps)
        # Setup build and install paths
        set(find_dependency_paths "\${CMAKE_CURRENT_LIST_DIR}/..")
        if(plugin_install_package_suffix)
            set(path_suffix "${INSTALL_CMAKE_NAMESPACE}${plugin_install_package_suffix}")
            if(plugin_install_package_suffix MATCHES "/QmlPlugins")
                # Qml plugins are one folder deeper.
                set(find_dependency_paths "\${CMAKE_CURRENT_LIST_DIR}/../..")
            endif()

        else()
            set(path_suffix "${INSTALL_CMAKE_NAMESPACE}${target}")
        endif()

        qt_path_join(config_build_dir ${QT_CONFIG_BUILD_DIR} ${path_suffix})
        qt_path_join(config_install_dir ${QT_CONFIG_INSTALL_DIR} ${path_suffix})

        # Configure and install ModuleDependencies file.
        configure_file(
            "${QT_CMAKE_DIR}/QtPluginDependencies.cmake.in"
            "${config_build_dir}/${INSTALL_CMAKE_NAMESPACE}${target}Dependencies.cmake"
            @ONLY
        )

        qt_install(FILES
            "${config_build_dir}/${INSTALL_CMAKE_NAMESPACE}${target}Dependencies.cmake"
            DESTINATION "${config_install_dir}"
            COMPONENT Devel
        )
    endif()
endfunction()

function(qt_internal_create_qt6_dependencies_file)
    # This is used for substitution in the configured file.
    set(target "${INSTALL_CMAKE_NAMESPACE}")

    # This is the actual target we're querying.
    set(actual_target Platform)
    get_target_property(public_depends "${actual_target}" INTERFACE_LINK_LIBRARIES)
    unset(depends)
    unset(optional_public_depends)

    # We need to collect third party deps that are set on the public Platform target,
    # like Threads::Threads.
    # This mimics find_package part of the CONFIG += thread assignment in mkspecs/features/qt.prf.
    qt_collect_third_party_deps(${actual_target})

    # For Threads we also need to write an extra variable assignment.
    set(third_party_extra "")
    if(third_party_deps MATCHES "Threads")
        string(APPEND third_party_extra "if(NOT QT_NO_THREADS_PREFER_PTHREAD_FLAG)
    set(THREADS_PREFER_PTHREAD_FLAG TRUE)
endif()")
    endif()

    if(third_party_deps)
        # Setup build and install paths.
        set(path_suffix "${INSTALL_CMAKE_NAMESPACE}")

        qt_path_join(config_build_dir ${QT_CONFIG_BUILD_DIR} ${path_suffix})
        qt_path_join(config_install_dir ${QT_CONFIG_INSTALL_DIR} ${path_suffix})

        # Configure and install QtDependencies file.
        configure_file(
            "${QT_CMAKE_DIR}/QtConfigDependencies.cmake.in"
            "${config_build_dir}/${target}Dependencies.cmake"
            @ONLY
        )

        qt_install(FILES
            "${config_build_dir}/${target}Dependencies.cmake"
            DESTINATION "${config_install_dir}"
            COMPONENT Devel
        )
    endif()
endfunction()

# Create Depends.cmake & Depends.h files for all modules and plug-ins.
function(qt_internal_create_depends_files)
    qt_internal_get_qt_repo_known_modules(repo_known_modules)

    if(PROJECT_NAME STREQUAL "QtBase")
        qt_internal_create_qt6_dependencies_file()
    endif()

    foreach (target ${repo_known_modules})
        qt_internal_create_module_depends_file(${target})
    endforeach()

    foreach (target ${QT_KNOWN_PLUGINS})
        qt_internal_create_plugin_depends_file(${target})
    endforeach()
endfunction()

# This function creates the Qt<Module>Plugins.cmake used to list all
# the plug-in target files.
function(qt_internal_create_plugins_files)
    # The plugins cmake configuration is only needed for static builds. Dynamic builds don't need
    # the application to link against plugins at build time.
    if(QT_BUILD_SHARED_LIBS)
        return()
    endif()
    qt_internal_get_qt_repo_known_modules(repo_known_modules)

    message("Generating Plugins files for ${repo_known_modules}...")
    foreach (QT_MODULE ${repo_known_modules})
        get_target_property(target_type "${QT_MODULE}" TYPE)
        if(target_type STREQUAL "INTERFACE_LIBRARY")
            # No plugins are provided by a header only module.
            continue()
        endif()
        qt_path_join(config_build_dir ${QT_CONFIG_BUILD_DIR} ${INSTALL_CMAKE_NAMESPACE}${QT_MODULE})
        qt_path_join(config_install_dir ${QT_CONFIG_INSTALL_DIR} ${INSTALL_CMAKE_NAMESPACE}${QT_MODULE})
        set(QT_MODULE_PLUGIN_INCLUDES "")

        get_target_property(qt_plugins "${QT_MODULE}" QT_PLUGINS)
        if(qt_plugins)
            foreach (pluginTarget ${qt_plugins})
                set(QT_MODULE_PLUGIN_INCLUDES "${QT_MODULE_PLUGIN_INCLUDES}include(\"\${CMAKE_CURRENT_LIST_DIR}/${INSTALL_CMAKE_NAMESPACE}${pluginTarget}Config.cmake\")\n")
            endforeach()
        endif()

        if(QT_MODULE STREQUAL "Qml")
            set(QT_MODULE_PLUGIN_INCLUDES "${QT_MODULE_PLUGIN_INCLUDES}
file(GLOB __qt_qml_plugins_config_file_list \"\${CMAKE_CURRENT_LIST_DIR}/QmlPlugins/${INSTALL_CMAKE_NAMESPACE}*Config.cmake\")
if (__qt_qml_plugins_config_file_list AND NOT QT_SKIP_AUTO_QML_PLUGIN_INCLUSION)
    foreach(__qt_qml_plugin_config_file \${__qt_qml_plugins_config_file_list})
        include(\${__qt_qml_plugin_config_file})
    endforeach()
endif()")
        endif()

        if(QT_MODULE_PLUGIN_INCLUDES)
            configure_file(
                "${QT_CMAKE_DIR}/QtPlugins.cmake.in"
                "${config_build_dir}/${INSTALL_CMAKE_NAMESPACE}${QT_MODULE}Plugins.cmake"
                @ONLY
            )
            qt_install(FILES
                "${config_build_dir}/${INSTALL_CMAKE_NAMESPACE}${QT_MODULE}Plugins.cmake"
                DESTINATION "${config_install_dir}"
                COMPONENT Devel
            )
        endif()
    endforeach()
endfunction()

function(qt_generate_install_prefixes out_var)
    set(content "\n")
    set(vars INSTALL_BINDIR INSTALL_INCLUDEDIR INSTALL_LIBDIR INSTALL_MKSPECSDIR INSTALL_ARCHDATADIR
        INSTALL_PLUGINSDIR INSTALL_LIBEXECDIR INSTALL_QMLDIR INSTALL_DATADIR INSTALL_DOCDIR
        INSTALL_TRANSLATIONSDIR INSTALL_SYSCONFDIR INSTALL_EXAMPLESDIR INSTALL_TESTSDIR
        INSTALL_DESCRIPTIONSDIR)

    foreach(var ${vars})
        get_property(docstring CACHE "${var}" PROPERTY HELPSTRING)
        string(APPEND content "set(${var} \"${${var}}\" CACHE STRING \"${docstring}\" FORCE)\n")
    endforeach()

    set(${out_var} "${content}" PARENT_SCOPE)
endfunction()

function(qt_wrap_string_in_if_multi_config content out_var)
    set(${out_var} "
get_property(__qt_is_multi_config GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(__qt_is_multi_config)
${content}endif()
unset(__qt_is_multi_config)\n" PARENT_SCOPE)
endfunction()

function(qt_wrap_string_in_if_ninja_multi_config content out_var)
    set(${out_var} "if(CMAKE_GENERATOR STREQUAL \"Ninja Multi-Config\")
${content}endif()\n" PARENT_SCOPE)
endfunction()

function(qt_create_hostinfo_package)
    set(package "${INSTALL_CMAKE_NAMESPACE}HostInfo")
    qt_path_join(config_file_path "${QT_CONFIG_BUILD_DIR}/${package}/${package}Config.cmake")
    qt_path_join(install_destination ${QT_CONFIG_INSTALL_DIR} ${package})
    set(var_prefix "QT${PROJECT_VERSION_MAJOR}_HOST_INFO_")
    configure_package_config_file(
        "${CMAKE_CURRENT_LIST_DIR}/QtHostInfoConfig.cmake.in"
        "${config_file_path}"
        INSTALL_DESTINATION "${install_destination}"
        NO_SET_AND_CHECK_MACRO
        NO_CHECK_REQUIRED_COMPONENTS_MACRO)
    qt_install(FILES "${config_file_path}" DESTINATION "${install_destination}")
endfunction()

function(qt_generate_build_internals_extra_cmake_code)
    if(PROJECT_NAME STREQUAL "QtBase")
        qt_create_hostinfo_package()

        foreach(var IN LISTS QT_BASE_CONFIGURE_TESTS_VARS_TO_EXPORT)
            string(APPEND QT_EXTRA_BUILD_INTERNALS_VARS "set(${var} \"${${var}}\" CACHE INTERNAL \"\")\n")
        endforeach()

        set(QT_SOURCE_TREE "${QtBase_SOURCE_DIR}")
        qt_path_join(extra_file_path
                     ${QT_CONFIG_BUILD_DIR}
                     ${INSTALL_CMAKE_NAMESPACE}BuildInternals/QtBuildInternalsExtra.cmake)

        if(CMAKE_BUILD_TYPE)
            # Need to force set, because CMake itself initializes a value for CMAKE_BUILD_TYPE
            # at the start of project configuration (with an empty value),
            # so we need to force override it.
            string(APPEND QT_EXTRA_BUILD_INTERNALS_VARS
                "set(CMAKE_BUILD_TYPE \"${CMAKE_BUILD_TYPE}\" CACHE STRING \"Choose the type of build.\" FORCE)\n")

        endif()
        if(CMAKE_CONFIGURATION_TYPES)
            string(APPEND multi_config_specific
                "    set(CMAKE_CONFIGURATION_TYPES \"${CMAKE_CONFIGURATION_TYPES}\" CACHE STRING \"\" FORCE)\n")
        endif()
        if(CMAKE_TRY_COMPILE_CONFIGURATION)
            string(APPEND multi_config_specific
                "    set(CMAKE_TRY_COMPILE_CONFIGURATION \"${CMAKE_TRY_COMPILE_CONFIGURATION}\")\n")
        endif()
        if(multi_config_specific)
            qt_wrap_string_in_if_multi_config(
                "${multi_config_specific}"
                multi_config_specific)
            string(APPEND QT_EXTRA_BUILD_INTERNALS_VARS "${multi_config_specific}")
        endif()

        if(QT_MULTI_CONFIG_FIRST_CONFIG)
            string(APPEND QT_EXTRA_BUILD_INTERNALS_VARS
                "\nset(QT_MULTI_CONFIG_FIRST_CONFIG \"${QT_MULTI_CONFIG_FIRST_CONFIG}\")\n")
        endif()
        # When building standalone tests against a multi-config Qt, we want to choose the first
        # configuration, rather than default to Debug.
        if(multi_config_specific)
            string(APPEND QT_EXTRA_BUILD_INTERNALS_VARS "
if(QT_BUILD_STANDALONE_TESTS)
    set(CMAKE_BUILD_TYPE \"\${QT_MULTI_CONFIG_FIRST_CONFIG}\" CACHE STRING \"Choose the type of build.\" FORCE)
endif()\n")
        endif()

        if(CMAKE_CROSS_CONFIGS)
            string(APPEND ninja_multi_config_specific
                "    set(CMAKE_CROSS_CONFIGS \"${CMAKE_CROSS_CONFIGS}\" CACHE STRING \"\")\n")
        endif()
        if(CMAKE_DEFAULT_BUILD_TYPE)
            string(APPEND ninja_multi_config_specific
                "    set(CMAKE_DEFAULT_BUILD_TYPE \"${CMAKE_DEFAULT_BUILD_TYPE}\" CACHE STRING \"\")\n")
        endif()
        if(CMAKE_DEFAULT_CONFIGS)
            string(APPEND ninja_multi_config_specific
                "    set(CMAKE_DEFAULT_CONFIGS \"${CMAKE_DEFAULT_CONFIGS}\" CACHE STRING \"\")\n")
        endif()
        if(ninja_multi_config_specific)
            qt_wrap_string_in_if_ninja_multi_config(
                "${ninja_multi_config_specific}"
                ninja_multi_config_specific)
            string(APPEND QT_EXTRA_BUILD_INTERNALS_VARS "${ninja_multi_config_specific}")
        endif()

        if(DEFINED BUILD_WITH_PCH)
            string(APPEND QT_EXTRA_BUILD_INTERNALS_VARS
                "set(BUILD_WITH_PCH \"${BUILD_WITH_PCH}\" CACHE STRING \"\")\n")
        endif()

        if(CMAKE_CROSSCOMPILING AND QT_BUILD_TOOLS_WHEN_CROSSCOMPILING)
            string(APPEND QT_EXTRA_BUILD_INTERNALS_VARS
                "set(QT_BUILD_TOOLS_WHEN_CROSSCOMPILING \"TRUE\" CACHE BOOL \"\" FORCE)\n")
        endif()

        if(ECM_ENABLE_SANITIZERS)
            string(APPEND QT_EXTRA_BUILD_INTERNALS_VARS
                "set(ECM_ENABLE_SANITIZERS \"${ECM_ENABLE_SANITIZERS}\" CACHE BOOL \"\" FORCE)\n")
        endif()

        # Save the default qpa platform.
        # Used by qtwayland/src/plugins/platforms/qwayland-generic/CMakeLists.txt. Otherwise
        # the DEFAULT_IF condition is evaluated incorrectly.
        if(DEFINED QT_QPA_DEFAULT_PLATFORM)
            string(APPEND QT_EXTRA_BUILD_INTERNALS_VARS
                "set(QT_QPA_DEFAULT_PLATFORM \"${QT_QPA_DEFAULT_PLATFORM}\" CACHE STRING \"\")\n")
        endif()

        # Save the supported and computed minimum CMake versions to ensure the same minimum is
        # checked for when building other child repos (qtsvg, etc).
        qt_internal_get_qt_supported_minimum_cmake_version(min_supported_version)
        qt_internal_get_computed_minimum_cmake_version(computed_min_version)
        string(APPEND QT_EXTRA_BUILD_INTERNALS_VARS
            "set(QT_MIN_SUPPORTED_CMAKE_VERSION \"${min_supported_version}\" CACHE STRING \"Minimum supported CMake version required to build Qt\")\n")
        string(APPEND QT_EXTRA_BUILD_INTERNALS_VARS
            "set(QT_COMPUTED_MIN_CMAKE_VERSION \"${computed_min_version}\" CACHE STRING \"Computed minimum CMake version required to build Qt\")\n")

        # Rpath related things that need to be re-used when building other repos.
        string(APPEND QT_EXTRA_BUILD_INTERNALS_VARS
            "set(CMAKE_INSTALL_RPATH \"${CMAKE_INSTALL_RPATH}\" CACHE STRING \"\")\n")
        if(DEFINED QT_DISABLE_RPATH)
            string(APPEND QT_EXTRA_BUILD_INTERNALS_VARS
                "set(QT_DISABLE_RPATH \"${QT_DISABLE_RPATH}\" CACHE STRING \"\")\n")
        endif()
        if(DEFINED QT_EXTRA_DEFINES)
            string(APPEND QT_EXTRA_BUILD_INTERNALS_VARS
                "set(QT_EXTRA_DEFINES \"${QT_EXTRA_DEFINES}\" CACHE STRING \"\")\n")
        endif()
        if(DEFINED QT_EXTRA_INCLUDEPATHS)
            string(APPEND QT_EXTRA_BUILD_INTERNALS_VARS
                "set(QT_EXTRA_INCLUDEPATHS \"${QT_EXTRA_INCLUDEPATHS}\" CACHE STRING \"\")\n")
        endif()
        if(DEFINED QT_EXTRA_FRAMEWORKPATHS)
            string(APPEND QT_EXTRA_BUILD_INTERNALS_VARS
                "set(QT_EXTRA_FRAMEWORKPATHS \"${QT_EXTRA_FRAMEWORKPATHS}\" CACHE STRING \"\")\n")
        endif()
        if(DEFINED QT_EXTRA_LIBDIRS)
            string(APPEND QT_EXTRA_BUILD_INTERNALS_VARS
                "set(QT_EXTRA_LIBDIRS \"${QT_EXTRA_LIBDIRS}\" CACHE STRING \"\")\n")
        endif()
        if(DEFINED QT_EXTRA_RPATHS)
            string(APPEND QT_EXTRA_BUILD_INTERNALS_VARS
                "set(QT_EXTRA_RPATHS \"${QT_EXTRA_RPATHS}\" CACHE STRING \"\")\n")
        endif()

        # Save pkg-config feature value to be able to query it internally as soon as BuildInternals
        # package is loaded. This is to avoid any pkg-config package from being found when
        # find_package(Qt6Core) is called in case if the feature was disabled.
        string(APPEND QT_EXTRA_BUILD_INTERNALS_VARS "
if(NOT QT_SKIP_BUILD_INTERNALS_PKG_CONFIG_FEATURE)
    set(FEATURE_pkg_config \"${FEATURE_pkg_config}\" CACHE STRING \"Using pkg-config\" FORCE)
endif()\n")

        # The OpenSSL root dir needs to be saved so that repos other than qtbase (like qtopcua) can
        # still successfully find_package(WrapOpenSSL) in the CI.
        # qmake saves any additional include paths passed via the configure like '-I/foo'
        # in mkspecs/qmodule.pri, so this file is the closest equivalent.
        if(DEFINED OPENSSL_ROOT_DIR)
            file(TO_CMAKE_PATH "${OPENSSL_ROOT_DIR}" openssl_root_cmake_path)
            string(APPEND QT_EXTRA_BUILD_INTERNALS_VARS
                   "set(OPENSSL_ROOT_DIR \"${openssl_root_cmake_path}\" CACHE STRING \"\")\n")
        endif()

        if(NOT "${CMAKE_STAGING_PREFIX}" STREQUAL "")
            string(APPEND QT_EXTRA_BUILD_INTERNALS_VARS
                "
# If no explicit CMAKE_STAGING_PREFIX is provided, force set the original Qt staging prefix,
if(\"$\{CMAKE_STAGING_PREFIX}\" STREQUAL \"\"
   AND NOT QT_BUILD_INTERNALS_NO_FORCE_SET_STAGING_PREFIX)
    set(CMAKE_STAGING_PREFIX \"${CMAKE_STAGING_PREFIX}\" CACHE PATH
        \"Staging path prefix, prepended onto install directories on the host machine.\" FORCE)
endif()
")
        endif()

        qt_generate_install_prefixes(install_prefix_content)

        string(APPEND QT_EXTRA_BUILD_INTERNALS_VARS "${install_prefix_content}")

        qt_compute_relative_path_from_cmake_config_dir_to_prefix()
        configure_file(
            "${CMAKE_CURRENT_LIST_DIR}/QtBuildInternalsExtra.cmake.in"
            "${extra_file_path}"
            @ONLY
        )
    endif()
endfunction()

# For every Qt module check if there any android dependencies that require
# processing.
function(qt_modules_process_android_dependencies)
    qt_internal_get_qt_repo_known_modules(repo_known_modules)
    foreach (target ${repo_known_modules})
        qt_android_dependencies(${target})
    endforeach()
endfunction()

function(qt_create_tools_config_files)
    # Create packages like Qt6CoreTools/Qt6CoreToolsConfig.cmake.
    foreach(module_name ${QT_KNOWN_MODULES_WITH_TOOLS})
        qt_export_tools("${module_name}")
    endforeach()
endfunction()

function(qt_internal_create_config_file_for_standalone_tests)
    set(standalone_tests_config_dir "StandaloneTests")
    qt_path_join(config_build_dir
                 ${QT_CONFIG_BUILD_DIR}
                 "${INSTALL_CMAKE_NAMESPACE}BuildInternals" "${standalone_tests_config_dir}")
    qt_path_join(config_install_dir
                 ${QT_CONFIG_INSTALL_DIR}
                 "${INSTALL_CMAKE_NAMESPACE}BuildInternals" "${standalone_tests_config_dir}")

    # Filter out bundled system libraries. Otherwise when looking for their dependencies
    # (like PNG for Freetype) FindWrapPNG is searched for during configuration of
    # standalone tests, and it can happen that Core or Gui features are not
    # imported early enough, which means FindWrapPNG will try to find a system PNG library instead
    # of the bundled one.
    set(modules)
    foreach(m ${QT_REPO_KNOWN_MODULES})
        get_target_property(target_type "${m}" TYPE)

        # Interface libraries are never bundled system libraries (hopefully).
        if(target_type STREQUAL "INTERFACE_LIBRARY")
            list(APPEND modules "${m}")
            continue()
        endif()

        get_target_property(is_3rd_party "${m}" QT_MODULE_IS_3RDPARTY_LIBRARY)
        if(NOT is_3rd_party)
            list(APPEND modules "${m}")
        endif()
    endforeach()

    list(JOIN modules " " QT_REPO_KNOWN_MODULES_STRING)
    string(STRIP "${QT_REPO_KNOWN_MODULES_STRING}" QT_REPO_KNOWN_MODULES_STRING)

    # Skip generating and installing file if no modules were built. This make sure not to install
    # anything when build qtx11extras on macOS for example.
    if(NOT QT_REPO_KNOWN_MODULES_STRING)
        return()
    endif()

    # Ceate a Config file that calls find_package on the modules that were built as part
    # of the current repo. This is used for standalone tests.
    configure_file(
        "${QT_CMAKE_DIR}/QtStandaloneTestsConfig.cmake.in"
        "${config_build_dir}/${PROJECT_NAME}TestsConfig.cmake"
        @ONLY
    )
    qt_install(FILES
        "${config_build_dir}/${PROJECT_NAME}TestsConfig.cmake"
        DESTINATION "${config_install_dir}"
        COMPONENT Devel
    )
endfunction()

function(qt_internal_install_prl_files)
    # Install prl files
    get_property(prl_install_dirs GLOBAL PROPERTY QT_PRL_INSTALL_DIRS)
    foreach(prl_install_dir ${prl_install_dirs})
        qt_install(DIRECTORY "${PROJECT_BINARY_DIR}/${prl_install_dir}/"
            DESTINATION ${prl_install_dir}
            FILES_MATCHING PATTERN "*.prl"
        )
    endforeach()
endfunction()
