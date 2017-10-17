# tells the linker to link to the static standard library instead of the dynamic one
# this is a macro because we need to change the cmake variables in the current scope
# SYNTAX:
#	set_static_stdlib()
#
macro(set_static_stdlib)
	IF(GCC)
		set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -static-libgcc")
		set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -static-libgcc -static-libstdc++")
		set(CMAKE_SHARED_LIBRARY_LINK_C_FLAGS "${CMAKE_SHARED_LIBRARY_LINK_C_FLAGS} -static-libgcc -s")
		set(CMAKE_SHARED_LIBRARY_LINK_CXX_FLAGS "${CMAKE_SHARED_LIBRARY_LINK_CXX_FLAGS} -static-libgcc -static-libstdc++ -s")
	ELSEIF(MSVC)	
		set(CompilerFlags
				CMAKE_SHARED_LIBRARY_LINK_C_FLAGS 
				CMAKE_SHARED_LIBRARY_LINK_CXX_FLAGS 
		)
		foreach(CompilerFlag ${CompilerFlags})
			string(REPLACE "/MD" "/MT" ${CompilerFlag} "${${CompilerFlag}}")
		endforeach()
	ENDIF()
	#TODO: more plattforms
endmacro()



# returns full pathes to external libs using find_library
# SYNTAX:
# 	find_libs(output_list_name 
#  		[lib1 ... libN]
#	)
# EXAMPLE:
#	find_libs(ext_lib_pathes opengl32 winmm pthreads)
#	MESSAGE(${ext_lib_pathes})
#
function(find_libs output_list)
    list(REMOVE_AT ARGV 0)
    foreach (lib ${ARGV})
        find_library(lib_path ${lib})
        if (${lib_path} STREQUAL "lib_path-NOTFOUND")
            message(FATAL_ERROR "couldn't find external library ${lib}")
        endif ()
        list(APPEND pathes ${lib_path})
        UNSET(lib_path CACHE)
    endforeach ()
    set(${path_list} ${pathes} PARENT_SCOPE)
endfunction()


# creates a merged lib that contains all the other passed libs.
# the created target is correctly rebuilt when any dependency changes
# merge_static_libs accepts static cmake targets and external static libs as inputs
# SYNTAX:
#	merge_libs(outputlib_target_name
#		[static_lib_target1 .... static_lib_targetN]
#		[EXTERNAL external_lib_path1 .... external_lib_pathN]
# 	)
# EXAMPLE:
#	add_library(tgt1 STATIC "src.c")
#	find_library(ogl_path "opengl32")
#	merge_static_libs(merged_lib tgt1 EXTERNAL ${ogl_path})
#	
#	##the merged lib can also be the final output, this is just to show that it's possible to use the target
#	add_executable(exec merged_lib) 
#
function(merge_static_libs outputlib)
   set(ext_libs "")
   set(tgt_libs "")
    # input handling
    list(REMOVE_AT ARGV 0)
    set(FOUND_EXTERNAL FALSE)
    foreach (lib ${ARGV})
        if (FOUND_EXTERNAL)
            list(APPEND ext_libs ${lib})
        elseif (${lib} STREQUAL "EXTERNAL")
            set(FOUND_EXTERNAL TRUE)
        else ()
            list(APPEND tgt_libs ${lib})
        endif ()
    endforeach ()
    # safety first
    list(REMOVE_DUPLICATES tgt_libs)
    list(REMOVE_DUPLICATES ext_libs)

    # put all lib pathes in a combined string so we can pass it to the respective tools
    # not on unix because there we have no such tool ...
    if (APPLE OR MSVC)
        foreach (lib ${tgt_libs})
            get_target_property(libtype ${lib} TYPE)
            if (NOT libtype STREQUAL "STATIC_LIBRARY")
                message(FATAL_ERROR "merge_static_libs can only handle process static libraries")
            endif ()
            set(libfiles "${libfiles} $<TARGET_FILE:${lib}>")
        endforeach ()
        foreach (ext_lib ${ext_libs})
            set(libfiles "${libfiles} ${ext_lib}")
        endforeach ()
    endif ()

    if (MSVC) 
	# msvc's default linker lib.exe can merge libs
        set_target_properties(${outputlib} PROPERTIES STATIC_LIBRARY_FLAGS "${libfiles}")

    elseif (APPLE) 
	# OSX's libtool can merge libs
        add_custom_command(TARGET ${outputlib} POST_BUILD
            COMMAND rm "$<TARGET_FILE:${outputlib}>"
            COMMAND /usr/bin/libtool -static -o "$<TARGET_FILE:${outputlib}>" ${libfiles})

    else ()
	# this should work on all posix systems 
	# initially, or whenever a library changes, we create it's obj files using ar
	# additionally, we create a dummy source file, that the merged library uses as an input src, making it a dependency
	# by doing that, we achieve that when a sublibrary changes, only it and the merged lib need to be rebuilt	
	# we create the merged lib using the extracted obj files with ar and ranlib
        set(MESS_DIR "${CMAKE_BINARY_DIR}/${outputlib}_mergefiles") #all our obj mess goes in this dir
        set(base_dummy_src "${MESS_DIR}/${outputlib}.dummy_src.c")
        add_custom_command(OUTPUT ${base_dummy_src}
            COMMAND ${CMAKE_COMMAND} -E make_directory ${MESS_DIR}
            COMMAND ${CMAKE_COMMAND} -E touch ${base_dummy_src})

        set(outputlib_path "$<TARGET_FILE:${outputlib}>")
        foreach (tgt_lib ${tgt_libs})
            set(objdir "${MESS_DIR}/${tgt_lib}.objdir")
            set(objlistfile ${MESS_DIR}/${tgt_lib}.objlist)
            set(lib_dummy_src "${MESS_DIR}/${tgt_lib}.dummy_src.c")
            set(lib_path "$<TARGET_FILE:${tgt_lib}>")
            add_custom_command(OUTPUT ${lib_dummy_src}
                COMMAND ${CMAKE_COMMAND} -E make_directory ${objdir}
                COMMAND cd ${objdir} && ${CMAKE_AR} -x "${lib_path}"
                COMMAND ${CMAKE_AR} -t "${lib_path}" > ${objlistfile}
                COMMAND ${CMAKE_COMMAND} -E touch ${lib_dummy_src}
                DEPENDS ${base_dummy_src} ${tgt_lib}
                )
            list(APPEND dummy_srcs ${lib_dummy_src})
        endforeach ()
        foreach (ext_lib_path ${ext_libs})
            get_filename_component(ext_lib_name ${ext_lib_path} NAME_WE)
            set(objdir "${MESS_DIR}/${ext_lib_name}.objdir")
            set(objlistfile ${MESS_DIR}/${ext_lib_name}.objlist)
            set(lib_dummy_src "${MESS_DIR}/${ext_lib_name}.dummy_src.c")
            add_custom_command(OUTPUT ${lib_dummy_src}
                COMMAND ${CMAKE_COMMAND} -E make_directory ${objdir}
                COMMAND cd ${objdir} && ${CMAKE_AR} -x "${ext_lib_path}"
                COMMAND ${CMAKE_AR} -t "${ext_lib_path}" > ${objlistfile}
                COMMAND ${CMAKE_COMMAND} -E touch ${lib_dummy_src}
                DEPENDS ${base_dummy_src} ${ext_lib_path}
                )
            list(APPEND dummy_srcs ${lib_dummy_src})
        endforeach ()

        add_library(${outputlib} STATIC ${dummy_srcs})

        foreach (tgt_lib ${tgt_libs})
            set(objdir "${MESS_DIR}/${tgt_lib}.objdir")
            set(objlistfile ${MESS_DIR}/${tgt_lib}.objlist)
            add_custom_command(TARGET ${outputlib} POST_BUILD
                COMMAND ${CMAKE_AR} -ru ${outputlib_path} @"${objlistfile}"
                WORKING_DIRECTORY ${objdir})
        endforeach ()
        foreach (ext_lib_path ${ext_libs})
            get_filename_component(ext_lib_name ${ext_lib_path} NAME_WE)
            set(objdir "${MESS_DIR}/${ext_lib_name}.objdir")
            set(objlistfile ${MESS_DIR}/${ext_lib_name}.objlist)
            add_custom_command(TARGET ${outputlib} POST_BUILD
                COMMAND ${CMAKE_AR} -ru ${outputlib_path} @"${objlistfile}"
                WORKING_DIRECTORY ${objdir})
        endforeach ()

        add_custom_command(TARGET ${outputlib} POST_BUILD
            COMMAND ${CMAKE_RANLIB} ${outputlib_path})
    endif ()
endfunction()
