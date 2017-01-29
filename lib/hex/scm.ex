defmodule Hex.SCM do
  alias Hex.Registry.Server, as: Registry
  @moduledoc false

  @behaviour Mix.SCM
  @packages_dir "packages"
  @request_timeout 60_000
  @fetch_timeout @request_timeout * 2

  def fetchable? do
    true
  end

  def format(_opts) do
    "Hex package"
  end

  def format_lock(opts) do
    case Hex.Utils.lock(opts[:lock]) do
      %{name: name, version: version, checksum: nil} ->
        "#{version} (#{name})"
      %{name: name, version: version, checksum: <<checksum::binary-8, _::binary>>} ->
        "#{version} (#{name}) #{checksum}"
      nil ->
        nil
    end
  end

  def accepts_options(name, opts) do
    opts
    |> Keyword.put_new(:hex, name)
    |> Keyword.put_new(:repo, "hexpm")
    |> Keyword.update!(:hex, &to_string/1)
    |> Keyword.update!(:repo, &to_string/1)
    |> put_original_repo(Keyword.fetch(opts, :repo))
  end

  defp put_original_repo(opts, {:ok, repo}),
    do: Keyword.put(opts, :original_repo, to_string(repo))
  defp put_original_repo(opts, :error),
    do: opts

  def checked_out?(opts) do
    File.dir?(opts[:dest])
  end

  def lock_status(opts) do
    case Hex.Utils.lock(opts[:lock]) do
      %{name: name, version: version, checksum: checksum, repo: repo} ->
        lock_status(opts[:dest], name, version, checksum, repo)
      nil ->
        :mismatch
    end
  end

  defp lock_status(dest, name, version, checksum, repo) do
    case File.read(Path.join(dest, ".hex")) do
      {:ok, file} ->
        case parse_manifest(file) do
          {^name, ^version, ^checksum, ^repo, _} -> :ok
          {^name, ^version, ^checksum, _} -> :ok
          {^name, ^version, ^checksum} -> :ok
          {^name, ^version, _} when is_nil(checksum) -> :ok
          {^name, ^version} -> :ok
          _ ->
            :mismatch
        end
      {:error, _} ->
        :mismatch
    end
  end

  def equal?(opts1, opts2) do
    opts1[:hex] == opts2[:hex]
  end

  def managers(opts) do
    case Hex.Utils.lock(opts[:lock]) do
      %{managers: managers} ->
        managers || []
      nil ->
        []
    end
  end

  def checkout(opts) do
    Registry.open

    lock     = Hex.Utils.lock(opts[:lock]) |> ensure_lock(opts)
    name     = opts[:hex]
    dest     = opts[:dest]
    repo     = opts[:repo]
    filename = "#{name}-#{lock.version}.tar"
    path     = cache_path(repo, filename)
    url      = Hex.State.fetch!(:repos)[repo].url <> "/tarballs/#{filename}"

    Hex.Shell.info "  Checking package (#{url})"

    case Hex.Parallel.await(:hex_fetcher, {:tarball, repo, name, lock.version}, @fetch_timeout) do
      {:ok, :cached} ->
        Hex.Shell.info "  Using locally cached package"
      {:ok, :offline} ->
        Hex.Shell.info "  [OFFLINE] Using locally cached package"
      {:ok, :new, etag} ->
        Registry.tarball_etag(repo, name, lock.version, etag)
        if Version.compare(System.version, "1.4.0") == :lt,
          do: Registry.persist
        Hex.Shell.info "  Fetched package"
      {:error, reason} ->
        Hex.Shell.error(reason)
        unless File.exists?(path) do
          Mix.raise "Package fetch failed and no cached copy available"
        end
        Hex.Shell.info "  Fetch failed. Using locally cached package"
    end

    File.rm_rf!(dest)

    meta = Hex.Tar.unpack(path, dest, repo, name, lock.version)
    build_tools = guess_build_tools(meta)
    managers =
      build_tools
      |> Enum.map(&String.to_atom/1)
      |> Enum.sort

    manifest = encode_manifest(name, lock.version, lock.checksum, repo, managers)
    File.write!(Path.join(dest, ".hex"), manifest)

    {:hex, lock.name, lock.version, lock.checksum, managers, Enum.sort(lock.deps), lock.repo}
  end

  def update(opts) do
    checkout(opts)
  end

  @build_tools [
    {"mix.exs"     , "mix"},
    {"rebar.config", "rebar"},
    {"rebar"       , "rebar"},
    {"Makefile"    , "make"},
    {"Makefile.win", "make"}
  ]

  def guess_build_tools(%{"build_tools" => tools}) do
    if tools,
      do: Enum.uniq(tools),
      else: []
  end

  def guess_build_tools(meta) do
    base_files =
      (meta["files"] || [])
      |> Enum.filter(&(Path.dirname(&1) == "."))
      |> Enum.into(Hex.Set.new)

    Enum.flat_map(@build_tools, fn {file, tool} ->
      if file in base_files,
          do: [tool],
        else: []
    end)
    |> Enum.uniq
  end

  defp ensure_lock(nil, opts) do
    Mix.raise "The lock is missing for package #{opts[:hex]}. This could be " <>
              "because another package has configured the application name " <>
              "for the dependency incorrectly. Verify with the maintainer " <>
              "the parent application"
  end
  defp ensure_lock(lock, _opts), do: lock

  def parse_manifest(file) do
    lines =
      file
      |> Hex.string_trim
      |> String.split("\n")

    case lines do
      [first] ->
        (String.split(first, ",") ++ [[]])
        |> List.to_tuple
      [first, managers] ->
        managers =
          managers
          |> String.split(",")
          |> Enum.map(&String.to_atom/1)
        (String.split(first, ",") ++ [managers])
        |> List.to_tuple
    end
  end

  defp encode_manifest(name, version, checksum, repo, managers) do
    managers = managers || []
    "#{name},#{version},#{checksum},#{repo}\n#{Enum.join(managers, ",")}"
  end

  defp cache_path(repo, name) do
    Path.join([Hex.State.fetch!(:home), @packages_dir, repo, name])
  end

  def prefetch(lock) do
    fetch = fetch_from_lock(lock)

    Enum.each(fetch, fn {repo, package, version} ->
      %{url: url} = Hex.State.fetch!(:repos)[repo]
      filename = "#{package}-#{version}.tar"
      path = cache_path(repo, filename)
      etag = File.exists?(path) && Registry.tarball_etag(repo, package, version)
      Hex.Parallel.run(:hex_fetcher, {:tarball, repo, package, version}, fn ->
        fetch(url, filename, path, etag)
      end)
    end)
  end

  defp fetch_from_lock(lock) do
    deps_path = Mix.Project.deps_path

    Enum.flat_map(lock, fn {app, info} ->
      case Hex.Utils.lock(info) do
        %{name: name, version: version, repo: repo} ->
          dest = Path.join(deps_path, "#{app}")
          case lock_status([dest: dest, lock: info]) do
            :ok       -> []
            :mismatch -> [{repo, name, version}]
            :outdated -> [{repo, name, version}]
          end
        nil ->
          []
      end
    end)
  end

  defp fetch(url, name, path, etag) do
    if Hex.State.fetch!(:offline?) do
      {:ok, :offline}
    else
      url = url <> "/tarballs/#{name}"

      case Hex.Repo.request(url, etag) do
        {:ok, body, etag} ->
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, body)
          {:ok, :new, etag}
        other ->
          other
      end
    end
  end
end
