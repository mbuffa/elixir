# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec

# This module is the one responsible for converging
# dependencies in a recursive fashion. This
# module and its functions are private to Mix.
defmodule Mix.Dep.Converger do
  @moduledoc false

  @doc """
  Topologically sorts the given dependencies.
  """
  def topological_sort(deps) do
    graph = :digraph.new()

    try do
      Enum.each(deps, fn %Mix.Dep{app: app} ->
        :digraph.add_vertex(graph, app)
      end)

      Enum.each(deps, fn %Mix.Dep{app: app, deps: other_deps} ->
        Enum.each(other_deps, fn
          %Mix.Dep{app: ^app} ->
            Mix.raise("App #{app} lists itself as a dependency")

          %Mix.Dep{app: other_app} ->
            :digraph.add_edge(graph, other_app, app)
        end)
      end)

      if apps = :digraph_utils.topsort(graph) do
        Enum.map(apps, fn app ->
          Enum.find(deps, fn %Mix.Dep{app: other_app} -> app == other_app end)
        end)
      else
        find_cycle(graph)
      end
    after
      :digraph.delete(graph)
    end
  end

  @doc """
  A Depth-First Search to find where is the dependency graph cycle
  and then display the cyclic dependencies back to the developer.
  """
  def find_cycle(graph), do: find_cycle(graph, :digraph.vertices(graph), MapSet.new())

  defp find_cycle(_, [], _visited), do: nil

  defp find_cycle(graph, [v | vs], visited) do
    if v in visited, do: cycle_found(visited)

    find_cycle(graph, :digraph.out_neighbours(graph, v), MapSet.put(visited, v))
    find_cycle(graph, vs, visited)
  end

  defp cycle_found(visited) do
    Mix.raise(
      "Could not sort dependencies. " <>
        "The following dependencies form a cycle: " <>
        Enum.join(visited, ", ")
    )
  end

  @doc """
  Converge without lock and accumulator updates.

  Note the dependencies returned from converge are not yet loaded.
  The relevant app keys are found under `dep.opts[:app_properties]`.

  See `Mix.Dep.Loader.children/1` for options.
  """
  def converge(opts \\ []) do
    converge(nil, nil, opts, &{&1, &2, &3}) |> elem(0)
  end

  @doc """
  Converges all dependencies from the current project,
  including nested dependencies.

  There is a callback that is invoked for each dependency and
  must return an updated dependency in case some processing
  is done.

  Note the dependencies returned from converge are not yet loaded.
  The relevant app keys are found under `dep.opts[:app_properties]`.

  See `Mix.Dep.Loader.children/1` for options.
  """
  def converge(acc, lock, opts, callback) do
    {deps, acc, lock} = all(acc, lock, opts, callback)
    if remote = Mix.RemoteConverger.get(), do: remote.post_converge()
    {topological_sort(deps), acc, lock}
  end

  defp all(acc, lock, opts, callback) do
    lock_given? = !!lock

    main = Mix.Dep.Loader.children(lock_given?)
    main = Enum.map(main, &%{&1 | top_level: true})
    apps = Enum.map(main, & &1.app)
    env_target = {opts[:env], opts[:target]}

    # If no lock was given, let's read one to fill in the deps
    lock = lock || Mix.Dep.Lock.read()

    # Run converger for all dependencies, except remote
    # dependencies. Since the remote converger may be
    # lazily loaded, we need to check for it on every
    # iteration.
    {deps, acc, lock} =
      init_all(main, apps, acc, lock, callback, lock_given?, env_target, fn dep ->
        if (remote = Mix.RemoteConverger.get()) && remote.remote?(dep) do
          {:loaded, dep}
        else
          {:unloaded, dep, nil}
        end
      end)

    # Run remote converger and rerun Mix's converger with the new information.
    # Don't run the remote if deps didn't converge, if the remote is not
    # available or if none of the deps are handled by the remote.
    remote = Mix.RemoteConverger.get()
    diverged? = Enum.any?(deps, &Mix.Dep.diverged?/1)
    use_remote? = !!remote and Enum.any?(deps, &remote.remote?/1)

    if not diverged? and use_remote? do
      # Make sure there are no cycles before calling the remote converger
      topological_sort(deps)

      # If there is a lock, it means we are doing a get/update
      # and we need to hit the remote converger which do external
      # requests and what not. In case of deps.loadpaths, deps and so
      # on, there is no lock, so we won't hit this branch.
      lock = if lock_given?, do: remote.converge(deps, lock), else: lock

      cache =
        deps
        |> Enum.reject(&remote.remote?(&1))
        |> Enum.into(%{}, &{&1.app, &1})

      # In case no lock was given, we will use the local lock
      # which is potentially stale. So remote.deps/2 needs to always
      # check if the data it finds in the lock is actually valid.
      {deps, acc, lock} =
        init_all(main, apps, acc, lock, callback, lock_given?, env_target, fn dep ->
          %{app: app, scm: scm} = dep

          case cache do
            # If the SCM matches, use the already cached dependency from first converger pass
            %{^app => %{scm: ^scm} = cached} ->
              {:loaded, cached}

            # If SCM doesn't match, the remote converger resolved a new dependency but because
            # there is conflict we return the new dependency as is for the converger to fail
            %{^app => _cached} ->
              {:loaded, dep}

            %{} ->
              {:unloaded, dep, remote.deps(dep, lock)}
          end
        end)

      {reject_non_fulfilled_optional(deps), acc, lock}
    else
      {reject_non_fulfilled_optional(deps), acc, lock}
    end
  end

  defp init_all(main, apps, rest, lock, callback, locked?, env_target, cache) do
    state = %{locked?: locked?, env_target: env_target, cache: cache, callback: callback}
    {deps, _kept, _optional, rest, lock} = all(main, [], [], [], apps, [], rest, lock, state)
    deps = Enum.reverse(deps)
    # When traversing dependencies, we keep skipped ones to
    # find conflicts. We remove them now after traversal.
    {deps, _} = Mix.Dep.Loader.split_by_env_and_target(deps, env_target)
    {deps, rest, lock}
  end

  # We traverse the tree of dependencies in a breadth-first
  # fashion. The reason for this is that we converge
  # dependencies, but allow the parent to override any
  # dependency in the child. Consider this tree with
  # dependencies "a", "b", "c", and so forth, and the order they are
  # converged:
  #
  #     * project
  #       1) a
  #       2) b
  #         4) d
  #       3) c
  #         5) e
  #         6) f
  #           7) d
  #
  # Note that the "d" dependency exists as a child of "b"
  # and child of "f". In case the dependency is the same,
  # we proceed. However, if there is a conflict, for instance
  # different Git repositories are used as source in each, we
  # raise an exception.
  #
  # In order to solve such dependencies, we allow the project
  # to specify the same dependency, but it will be considered
  # to have higher priority:
  #
  #     * project
  #       1) a
  #       2) b
  #         5) d
  #       3) c
  #         6) e
  #         7) f
  #           8) d
  #       4) d
  #
  # Now, since "d" was specified in a parent project, no
  # exception is going to be raised since d is considered
  # to be the authoritative source.
  defp all([dep | t], acc, kept, upper, breadths, optional, rest, lock, state) do
    case match_deps(acc, upper, dep, state.env_target) do
      {:replace, dep, acc} ->
        all([dep | t], acc, kept, upper, breadths, optional, rest, lock, state)

      {:match, acc} ->
        all(t, acc, kept, upper, breadths, optional, rest, lock, state)

      :skip ->
        # We still keep skipped dependencies around to detect conflicts.
        # They must be rejected after every all iteration but they are not
        # included in the list of kept dependencies.
        all(t, [dep | acc], kept, upper, breadths, optional, rest, lock, state)

      :nomatch ->
        {%{app: app, deps: deps, opts: opts} = dep, rest, lock} =
          case state.cache.(dep) do
            {:loaded, cached_dep} ->
              {cached_dep, rest, lock}

            {:unloaded, dep, children} ->
              {dep, rest, lock} = state.callback.(put_lock(dep, lock), rest, lock)

              dep =
                Mix.Dep.Loader.with_system_env(dep, fn ->
                  Mix.Dep.Loader.load(dep, children, state.locked?)
                end)

              {dep, rest, lock}
          end

        # Something that we previously ruled out as an optional dependency is
        # no longer a dependency. Add it back for traversal.
        {no_longer_optional, optional} = Enum.split_with(optional, &(&1.app == app))
        t = no_longer_optional ++ t

        {acc, kept, optional, rest, lock} =
          all(t, [dep | acc], [dep.app | kept], upper, breadths, optional, rest, lock, state)

        # Now traverse all parent dependencies and see if we have any optional dependency.
        {discarded, deps} = split_non_fulfilled_optional(deps, kept, opts[:from_umbrella])

        new_breadths = Enum.map(deps, & &1.app) ++ breadths
        all(deps, acc, kept, breadths, new_breadths, discarded ++ optional, rest, lock, state)
    end
  end

  defp all([], acc, kept, _upper, _current, optional, rest, lock, _state) do
    {acc, kept, optional, rest, lock}
  end

  defp put_lock(%Mix.Dep{app: app} = dep, lock) do
    put_in(dep.opts[:lock], lock[app])
  end

  # Look for matching and divergence in dependencies.
  #
  # If the same dependency is specified more than once,
  # we need to guarantee they converge. If they don't
  # converge, we mark them as diverged.
  #
  # The only exception is when the dependency that
  # diverges is in the upper breadth, in those cases we
  # also check for the override option and mark the dependency
  # as overridden instead of diverged.
  defp match_deps(list, upper_breadths, %Mix.Dep{app: app} = dep, env_target) do
    case Enum.split_while(list, &(&1.app != app)) do
      {_, []} ->
        if Mix.Dep.Loader.skip?(dep, env_target) do
          :skip
        else
          :nomatch
        end

      {pre, [%Mix.Dep{opts: other_opts} = other | pos]} ->
        in_upper? = app in upper_breadths

        if other.top_level and dep.top_level do
          Mix.shell().error(
            "warning: the dependency #{inspect(dep.app)} is " <>
              "duplicated at the top level, please remove one of them"
          )
        end

        cond do
          in_upper? && other_opts[:override] ->
            {:match, list}

          not converge?(other, dep) ->
            tag = if in_upper?, do: :overridden, else: :diverged
            other = %{other | status: {tag, dep}}
            {:match, pre ++ [other | pos]}

          vsn = req_mismatch(other, dep) ->
            other = %{other | status: {:divergedreq, vsn, dep}}
            {:match, pre ++ [other | pos]}

          not in_upper? and Mix.Dep.Loader.skip?(other, env_target) and
              not Mix.Dep.Loader.skip?(dep, env_target) ->
            dep =
              dep
              |> with_matching_only_and_targets(other, in_upper?)
              |> merge_manager(other, in_upper?)

            {:replace, dep, pre ++ pos}

          true ->
            other =
              other
              |> with_matching_only_and_targets(dep, in_upper?)
              |> merge_manager(dep, in_upper?)

            {:match, pre ++ [other | pos]}
        end
    end
  end

  defp with_matching_only_and_targets(other, dep, in_upper?) do
    %{opts: opts} = dep

    if opts[:optional] do
      other
    else
      other
      |> with_matching(:only, dep, opts, in_upper?)
      |> with_matching(:targets, dep, opts, in_upper?)
    end
  end

  # When in_upper is true
  #
  # When a parent dependency specifies :only/:targets that is a
  # subset of a child dependency, we are going to abort as the
  # parent dependency must explicitly outline a superset of child
  # dependencies.
  #
  # We could resolve such conflicts automatically but, since
  # the user has likely written a :only/:targets in their mix.exs
  # file, we decided to go with a more explicit approach of asking
  # them to change it to avoid later surprises and headaches.
  defp with_matching(%{opts: other_opts} = other, key, dep, opts, true) do
    case Keyword.fetch(other_opts, key) do
      {:ok, other_value} ->
        case Keyword.fetch(opts, key) do
          {:ok, value} ->
            case List.wrap(value) -- List.wrap(other_value) do
              [] -> other
              _ -> %{other | status: {:"diverged#{key}", dep}}
            end

          :error ->
            %{other | status: {:"diverged#{key}", dep}}
        end

      :error ->
        other
    end
  end

  # When in_upper is false
  #
  # In this case, the two dependencies do not have a common path and
  # only solution is to merge the environments. We have decided to
  # perform it automatically as, opposite to in_upper above, the
  # dependencies are never really laid out in the parent tree.
  defp with_matching(%{opts: other_opts} = other, key, _dep, opts, false) do
    other_value = Keyword.get(other_opts, key)
    value = Keyword.get(opts, key)

    if other_value && value do
      put_in(other.opts[key], Enum.uniq(List.wrap(other_value) ++ List.wrap(value)))
    else
      %{other | opts: Keyword.delete(other_opts, key)}
    end
  end

  defp converge?(
         %Mix.Dep{scm: scm1, opts: opts1, system_env: system_env1},
         %Mix.Dep{scm: scm2, opts: opts2, system_env: system_env2}
       ) do
    scm1 == scm2 and system_env1 == system_env2 and opts_equal?(opts1, opts2) and
      scm1.equal?(opts1, opts2)
  end

  defp opts_equal?(opts1, opts2) do
    keys = ~w(app env compile manager)a
    Enum.all?(keys, &(Keyword.fetch(opts1, &1) == Keyword.fetch(opts2, &1)))
  end

  defp reject_non_fulfilled_optional(deps) do
    apps = Enum.map(deps, & &1.app)

    for dep <- deps do
      {_discarded, deps} = split_non_fulfilled_optional(dep.deps, apps, dep.opts[:from_umbrella])
      %{dep | deps: deps}
    end
  end

  defp split_non_fulfilled_optional(children, upper_breadths, umbrella?) do
    Enum.split_with(children, fn %Mix.Dep{app: app, opts: opts} ->
      opts[:optional] && app not in upper_breadths && !umbrella?
    end)
  end

  defp merge_manager(%{manager: other_manager} = other, %{manager: manager}, in_upper?) do
    %{other | manager: sort_manager(other_manager, manager, in_upper?)}
  end

  @managers [:mix, :rebar3, :make]

  defp sort_manager(other_manager, manager, true) do
    other_manager || manager
  end

  defp sort_manager(other_manager, manager, false) do
    to_exclude = @managers -- (List.wrap(other_manager) ++ List.wrap(manager))
    List.first(@managers -- to_exclude) || other_manager || manager
  end

  defp req_mismatch(%Mix.Dep{status: status}, %Mix.Dep{app: app, requirement: requirement}) do
    with {:ok, vsn} when not is_nil(vsn) <- status,
         true <- Mix.Dep.Loader.vsn_match(requirement, vsn, app) != {:ok, true} do
      vsn
    else
      _ -> nil
    end
  end
end
