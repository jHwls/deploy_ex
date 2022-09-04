defmodule DeployExHelpers do
  def app_name, do: Mix.Project.get() |> Module.split |> hd
  def underscored_app_name, do: Macro.underscore(app_name())

  def check_in_umbrella do
    if Mix.Project.umbrella?() do
      :ok
    else
      {:error, ErrorMessage.bad_request("must be in umbrella root")}
    end
  end

  def priv_file(priv_subdirectory) do
    :deploy_ex
      |> :code.priv_dir
      |> Path.join(priv_subdirectory)
  end

  def write_template(template_path, output_path, variables, opts) do
    output_file = EEx.eval_file(template_path, assigns: variables)

    opts = if File.exists?(output_path) do
      [{:message, [:green, "* rewriting ", :reset, output_path]} | opts]
    else
      opts
    end

    DeployExHelpers.write_file(output_path, output_file, opts)
  end

  def write_file(file_path, contents, opts) do
    if opts[:message] do
      if opts[:force] || Mix.Generator.overwrite?(file_path, contents) do
        if not File.exists?(Path.dirname(file_path)) do
          File.mkdir_p!(Path.dirname(file_path))
        end

        File.write!(file_path, contents)

        if !opts[:quiet] do
          Mix.shell().info(opts[:message])
        end
      end
    else
      Mix.Generator.create_file(file_path, contents, opts)
    end
  end

  def check_file_exists!(file_path) do
    if !File.exists?(file_path) do
      raise to_string(IO.ANSI.format([
        :red, "Cannot find ",
        :bright, "#{file_path}", :reset
      ]))
    end
  end

  def upper_title_case(string) do
    string |> String.split(~r/_|-/) |> Enum.map_join(" ", &String.capitalize/1)
  end

  def run_command_with_input(command, directory) do
    port = Port.open({:spawn, command}, [
      :nouse_stdio,
      :exit_status,
      {:cd, directory}
    ])

    receive do
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, code}} -> {:error, ErrorMessage.internal_server_error("couldn't run #{command}", %{code: code})}
    end
  end

  def fetch_mix_releases do
    case Mix.Project.get() do
      nil -> {:error, ErrorMessage.not_found("couldn't find mix project")}
      project -> {:ok, project.releases()}
    end
  end
end
