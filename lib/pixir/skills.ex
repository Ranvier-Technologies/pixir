defmodule Pixir.Skills do
  @moduledoc """
  Progressive-disclosure Skill discovery and loading (ADR 0010).

  Skills are instruction packages rooted outside the ordinary Workspace file tool
  authority. This module is the narrow Skills surface: list bounded metadata first,
  then load a selected `SKILL.md` or supporting file from registered roots.
  """

  alias Pixir.{Paths, Tool}

  @index_budget 8_000
  @scope_precedence %{"repo" => 0, "user" => 1, "pixir-global" => 2}
  @skill_name ~r/[A-Za-z0-9][A-Za-z0-9_.:-]*/
  @template_id ~r/^[A-Za-z0-9][A-Za-z0-9_.-]*$/
  @placeholder ~r/\{\{\s*([A-Za-z0-9_][A-Za-z0-9_.-]*)\s*\}\}/

  @type skill :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:scope) => String.t(),
          required(:source) => String.t(),
          required(:root) => String.t(),
          required(:dir) => String.t(),
          required(:path) => String.t(),
          required(:short_path) => String.t(),
          optional(:disable_model_invocation) => boolean()
        }

  @type workflow_template :: %{
          required(:id) => String.t(),
          required(:template_id) => String.t(),
          required(:version) => pos_integer(),
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:skill) => String.t(),
          required(:scope) => String.t(),
          required(:source) => String.t(),
          required(:path) => String.t(),
          required(:short_path) => String.t(),
          required(:parameters) => map(),
          required(:workflow) => map()
        }

  @doc "Discover registered Skills for a workspace, resolving duplicate names by scope."
  @spec discover(String.t(), keyword()) :: {:ok, %{skills: [skill()], warnings: [map()]}}
  def discover(workspace \\ File.cwd!(), opts \\ []) do
    candidates =
      workspace
      |> roots(opts)
      |> Enum.flat_map(&discover_root/1)

    {:ok, resolve_collisions(candidates)}
  end

  @doc "Resolve a Skill name from the selected discovery set."
  @spec get(String.t(), String.t(), keyword()) :: {:ok, skill()} | {:error, map()}
  def get(name, workspace \\ File.cwd!(), opts \\ []) when is_binary(name) do
    with {:ok, %{skills: skills}} <- discover(workspace, opts) do
      case Enum.find(skills, &(&1.name == name)) do
        nil ->
          {:error,
           Tool.error(:not_found, "skill not found", %{
             name: name,
             known: Enum.map(skills, & &1.name)
           })}

        skill ->
          {:ok, skill}
      end
    end
  end

  @doc "Read `SKILL.md` or a supporting file from a registered Skill."
  @spec view(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{skill: skill(), path: String.t(), abs_path: String.t(), content: String.t()}}
          | {:error, map()}
  def view(name, rel_path \\ "SKILL.md", workspace \\ File.cwd!(), opts \\ [])
      when is_binary(name) and is_binary(rel_path) do
    with {:ok, skill} <- get(name, workspace, opts),
         {:ok, abs_path} <- confine(skill.dir, rel_path),
         {:ok, content} <- read_file(abs_path, name, rel_path) do
      {:ok, %{skill: skill, path: normalize_rel(rel_path), abs_path: abs_path, content: content}}
    end
  end

  @doc """
  Discover Workflow Templates shipped by registered Skills.

  Templates live under `workflows/*.json` inside a Skill. Discovery reads only template
  metadata/resources and never executes Skill scripts or records Skill Activations.
  """
  @spec workflow_templates(String.t(), keyword()) ::
          {:ok, %{templates: [workflow_template()], warnings: [map()]}}
  def workflow_templates(workspace \\ File.cwd!(), opts \\ []) do
    with {:ok, %{skills: skills, warnings: skill_warnings}} <- discover(workspace, opts) do
      {templates, template_warnings} =
        Enum.reduce(skills, {[], []}, fn skill, {templates, warnings} ->
          {skill_templates, skill_warnings} = load_workflow_templates(skill)
          {templates ++ skill_templates, warnings ++ skill_warnings}
        end)

      {:ok,
       %{
         templates: Enum.sort_by(templates, & &1.template_id),
         warnings: skill_warnings ++ template_warnings
       }}
    end
  end

  @doc "Resolve a Workflow Template by `skill/template`, `skill:template`, or unique id."
  @spec workflow_template(String.t(), String.t(), keyword()) ::
          {:ok, workflow_template()} | {:error, map()}
  def workflow_template(ref, workspace \\ File.cwd!(), opts \\ [])

  def workflow_template(ref, workspace, opts) when is_binary(ref) do
    case split_template_ref(ref) do
      {nil, id} ->
        with {:ok, %{templates: templates}} <- workflow_templates(workspace, opts) do
          resolve_template_ref(templates, id)
        end

      {skill_name, id} ->
        load_workflow_template_ref(skill_name, id, workspace, opts)
    end
  end

  def workflow_template(_ref, _workspace, _opts),
    do: {:error, Tool.error(:invalid_args, "template_id must be a string", %{})}

  @doc """
  Instantiate a Skill Workflow Template into a concrete Workflow spec.

  The instantiated workflow is still executed by `Pixir.Workflows`; this function only
  validates template arguments and substitutes placeholders in the template resource.
  """
  @spec instantiate_workflow_template(String.t(), map(), String.t(), keyword()) ::
          {:ok, %{template: map(), workflow: map()}} | {:error, map()}
  def instantiate_workflow_template(ref, args, workspace \\ File.cwd!(), opts \\ [])

  def instantiate_workflow_template(ref, args, workspace, opts)
      when is_binary(ref) and is_map(args) do
    with {:ok, template} <- workflow_template(ref, workspace, opts),
         {:ok, bindings} <- template_bindings(template, args),
         {:ok, workflow} <- render_template_value(template.workflow, bindings) do
      {:ok,
       %{
         template: template_metadata(template),
         workflow: workflow
       }}
    end
  end

  def instantiate_workflow_template(ref, _args, _workspace, _opts) when is_binary(ref),
    do: {:error, Tool.error(:invalid_args, "template_args must be an object", %{})}

  def instantiate_workflow_template(_ref, _args, _workspace, _opts),
    do: {:error, Tool.error(:invalid_args, "template_id must be a string", %{})}

  @doc "Whether a viewed path is the Skill's main instruction file."
  @spec main_file?(String.t()) :: boolean()
  def main_file?(path), do: normalize_rel(path) == "SKILL.md"

  @doc "Build durable activation data for a loaded main `SKILL.md`."
  @spec activation_data(skill(), String.t(), String.t()) :: map()
  def activation_data(skill, content, activated_by) do
    %{
      "name" => skill.name,
      "description" => skill.description,
      "scope" => skill.scope,
      "source" => skill.source,
      "root" => skill.root,
      "path" => skill.path,
      "short_path" => skill.short_path,
      "content_hash" => sha256(content),
      "content" => content,
      "activated_by" => activated_by
    }
  end

  @doc "Render a compact Skills index for the Turn system prompt."
  @spec render_index(String.t(), keyword()) :: String.t()
  def render_index(workspace \\ File.cwd!(), opts \\ []) do
    {:ok, %{skills: skills}} = discover(workspace, opts)

    visible_skills =
      skills
      |> Enum.reject(&Map.get(&1, :disable_model_invocation, false))
      |> Enum.sort_by(&{&1.name, &1.short_path})

    body =
      cond do
        visible_skills == [] ->
          "<available_skills></available_skills>"

        true ->
          visible_skills
          |> Enum.map_join("\n", fn skill ->
            """
              <skill>
                <name>#{text(skill.name)}</name>
                <when_to_use>#{text(skill.description)}</when_to_use>
                <location>#{text(skill.short_path)}</location>
              </skill>
            """
            |> String.trim_trailing()
          end)
          |> then(&"<available_skills>\n#{&1}\n</available_skills>")
      end

    """
    The following Skills are routing metadata for specialized tasks, not content to
    report back to the user. Do not list or summarize Skills unless the user asks
    what Skills are available.
    Use `skill_view` to load a Skill's file only when the user explicitly invokes a
    Skill or the task clearly matches its `when_to_use` field.
    If a Skill file references a relative path, resolve it against the Skill directory.

    #{Tool.truncate(body, Keyword.get(opts, :budget, @index_budget))}

    `skills_list` can refresh this bounded routing index when needed. Calling `skill_view` for `SKILL.md`,
    or an explicit `$skill-name`/`/skill-name` invocation, records a durable per-Turn
    Skill Activation. Supporting files, including Workflow Templates, are loaded only
    when explicitly referenced.
    """
    |> String.trim()
  end

  @doc """
  Stable hash for the bounded Skills index rendered into a Turn prompt.

  This is intentionally a deterministic pure helper returning `String.t()` directly.
  It unwraps `Pixir.Provider.Cache.stable_hash/1` because index rendering already
  controls the input shape. Fallible public operations keep the usual
  `{:ok, term} | {:error, term}` shape.
  """
  @spec index_hash(String.t(), keyword()) :: String.t()
  def index_hash(workspace \\ File.cwd!(), opts \\ []) do
    with {:ok, hash} <-
           workspace
           |> render_index(opts)
           |> Pixir.Provider.Cache.stable_hash() do
      hash
    else
      {:error, reason} ->
        raise ArgumentError, "failed to hash skills index: #{Exception.message(reason)}"
    end
  end

  @doc "Find explicit `$skill-name` and leading `/skill-name` mentions in user text."
  @spec invoked_names(String.t()) :: [String.t()]
  def invoked_names(text) when is_binary(text) do
    slash =
      case Regex.run(~r/^\/(#{Regex.source(@skill_name)})\b/, String.trim_leading(text)) do
        [_, name] -> [name]
        _ -> []
      end

    dollar =
      ~r/(?:^|\s)\$(#{Regex.source(@skill_name)})\b/
      |> Regex.scan(text, capture: :all_but_first)
      |> List.flatten()

    Enum.uniq(slash ++ dollar)
  end

  @doc "Resolve explicit user-invoked Skills to activation data."
  @spec activations_for_prompt(String.t(), String.t(), keyword()) :: [map()]
  def activations_for_prompt(workspace, prompt, opts \\ []) do
    prompt
    |> invoked_names()
    |> Enum.flat_map(fn name ->
      case view(name, "SKILL.md", workspace, opts) do
        {:ok, %{skill: skill, content: content}} -> [activation_data(skill, content, "user")]
        {:error, _} -> []
      end
    end)
  end

  @doc "Render a durable activation as a Provider input fragment."
  @spec render_activation(map()) :: String.t()
  def render_activation(data) when is_map(data) do
    """
    <skill name="#{attr(data["name"])}" source="#{attr(data["source"] || data["scope"])}" path="#{attr(data["path"])}" content_sha256="#{attr(data["content_hash"])}">
    #{data["content"] || ""}
    </skill>
    """
    |> String.trim()
  end

  # ── roots / discovery ───────────────────────────────────────────────────

  defp roots(workspace, opts) do
    case Keyword.get(opts, :roots) do
      roots when is_list(roots) ->
        Enum.map(roots, &normalize_root/1)

      _ ->
        [
          %{scope: "repo", path: Path.join(repo_root(workspace), ".agents/skills")},
          %{scope: "user", path: Path.join(user_home(opts), ".agents/skills")},
          %{scope: "pixir-global", path: global_skills_dir(opts)}
        ]
        |> Enum.map(&normalize_root/1)
        |> Enum.uniq_by(&{&1.scope, &1.path})
    end
  end

  defp normalize_root(%{scope: scope, path: path}) when is_binary(scope) and is_binary(path) do
    %{
      scope: scope,
      source: scope,
      path: Path.expand(path),
      precedence: Map.get(@scope_precedence, scope, 99)
    }
  end

  defp normalize_root({scope, path}), do: normalize_root(%{scope: to_string(scope), path: path})

  defp discover_root(%{path: root} = root_info) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.flat_map(&load_candidate(root_info, &1))

      {:error, _} ->
        []
    end
  end

  defp load_candidate(root_info, entry) do
    dir = Path.join(root_info.path, entry)
    skill_path = Path.join(dir, "SKILL.md")

    if File.dir?(dir) and File.regular?(skill_path) do
      case File.read(skill_path) do
        {:ok, content} -> [skill_from(root_info, dir, skill_path, content)]
        {:error, _} -> []
      end
    else
      []
    end
  end

  # ── Workflow Templates ──────────────────────────────────────────────────

  defp load_workflow_templates(skill) do
    template_dir = Path.join(skill.dir, "workflows")

    case File.ls(template_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort()
        |> Enum.reduce({[], []}, fn entry, {templates, warnings} ->
          path = Path.join(template_dir, entry)

          case load_workflow_template(skill, path) do
            {:ok, template} -> {templates ++ [template], warnings}
            {:error, warning} -> {templates, warnings ++ [warning]}
          end
        end)

      {:error, :enoent} ->
        {[], []}

      {:error, reason} ->
        {[],
         [
           template_warning(skill, "workflows", "could not list workflow templates", %{
             reason: reason
           })
         ]}
    end
  end

  defp load_workflow_template(skill, path) do
    with {:ok, content} <- read_template_file(skill, path),
         {:ok, decoded} <- decode_template_json(skill, path, content),
         {:ok, template} <- validate_template(skill, path, decoded) do
      {:ok, template}
    end
  end

  defp load_workflow_template_ref(skill_name, id, workspace, opts) do
    with :ok <- validate_template_ref_id(id),
         {:ok, skill} <- get(skill_name, workspace, opts) do
      path = Path.join([skill.dir, "workflows", "#{id}.json"])

      cond do
        not File.regular?(path) ->
          {:error,
           Tool.error(:not_found, "workflow template not found", %{
             template_id: "#{skill_name}/#{id}",
             path: Path.relative_to(path, skill.dir)
           })}

        true ->
          case load_workflow_template(skill, path) do
            {:ok, template} ->
              {:ok, template}

            {:error, warning} ->
              {:error,
               Tool.error(:invalid_args, "workflow template is invalid", %{
                 template_id: "#{skill_name}/#{id}",
                 warning: warning
               })}
          end
      end
    end
  end

  defp validate_template_ref_id(id) do
    if Regex.match?(@template_id, id) do
      :ok
    else
      {:error, Tool.error(:invalid_args, "workflow template id is invalid", %{id: id})}
    end
  end

  defp read_template_file(skill, path) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, reason} ->
        {:error,
         template_warning(skill, path, "could not read workflow template", %{reason: reason})}
    end
  end

  defp decode_template_json(skill, path, content) do
    case Jason.decode(content) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, error} ->
        {:error,
         template_warning(skill, path, "workflow template is not valid JSON", %{
           reason: Exception.message(error)
         })}
    end
  end

  defp validate_template(skill, path, raw) when is_map(raw) do
    id =
      raw
      |> field("id")
      |> blank_to_nil()
      |> Kernel.||(Path.basename(path, ".json"))

    workflow = field(raw, "workflow")
    parameters = field(raw, "parameters", %{})
    version = field(raw, "version", 1)

    cond do
      not Regex.match?(@template_id, id) ->
        {:error,
         template_warning(skill, path, "workflow template id is invalid", %{
           id: id
         })}

      not supported_template_version?(version) ->
        {:error,
         template_warning(skill, path, "workflow template version is unsupported", %{
           id: id,
           version: version,
           supported: [1]
         })}

      not is_map(parameters) ->
        {:error,
         template_warning(skill, path, "workflow template parameters must be an object", %{
           id: id
         })}

      not valid_parameters?(parameters) ->
        {:error,
         template_warning(skill, path, "workflow template parameter definitions are invalid", %{
           id: id
         })}

      not is_map(workflow) ->
        {:error,
         template_warning(skill, path, "workflow template requires a workflow object", %{
           id: id
         })}

      true ->
        {:ok,
         %{
           id: id,
           template_id: "#{skill.name}/#{id}",
           version: 1,
           name: blank_to_nil(field(raw, "name")) || id,
           description: blank_to_nil(field(raw, "description")) || "",
           skill: skill.name,
           scope: skill.scope,
           source: skill.source,
           path: path,
           short_path:
             "#{skill.scope}:#{Path.basename(skill.dir)}/#{Path.relative_to(path, skill.dir)}",
           parameters: parameters,
           workflow: workflow
         }}
    end
  end

  defp validate_template(skill, path, _raw) do
    {:error, template_warning(skill, path, "workflow template must be an object", %{})}
  end

  defp valid_parameters?(parameters) do
    Enum.all?(parameters, fn
      {name, config} when is_binary(name) and is_map(config) ->
        template_arg_type(config) in ~w(string integer number boolean array object any)

      _ ->
        false
    end)
  end

  defp supported_template_version?(1), do: true
  defp supported_template_version?("1"), do: true
  defp supported_template_version?(_version), do: false

  defp resolve_template_ref(templates, ref) do
    {skill_name, id} = split_template_ref(ref)

    matches =
      Enum.filter(templates, fn template ->
        template.id == id and (is_nil(skill_name) or template.skill == skill_name)
      end)

    case matches do
      [template] ->
        {:ok, template}

      [] ->
        {:error,
         Tool.error(:not_found, "workflow template not found", %{
           template_id: ref,
           known: Enum.map(templates, & &1.template_id)
         })}

      matches ->
        {:error,
         Tool.error(:invalid_args, "workflow template id is ambiguous", %{
           template_id: ref,
           matches: Enum.map(matches, & &1.template_id)
         })}
    end
  end

  defp split_template_ref(ref) do
    cond do
      String.contains?(ref, "/") ->
        [skill, id] = String.split(ref, "/", parts: 2)
        {blank_to_nil(skill), id}

      String.contains?(ref, ":") ->
        [skill, id] = String.split(ref, ":", parts: 2)
        {blank_to_nil(skill), id}

      true ->
        {nil, ref}
    end
  end

  defp template_bindings(template, args) do
    parameters = template.parameters
    known = Map.keys(parameters)
    unknown = Map.keys(args) -- known

    cond do
      unknown != [] ->
        {:error,
         Tool.error(:invalid_args, "unknown workflow template arguments", %{
           template_id: template.template_id,
           unknown: unknown,
           known: known
         })}

      true ->
        parameters
        |> Enum.reduce_while({:ok, %{}}, fn {name, config}, {:ok, acc} ->
          case template_arg_value(template, name, config, args) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)
    end
  end

  defp template_arg_value(template, name, config, args) do
    cond do
      Map.has_key?(args, name) ->
        validate_template_arg(template, name, config, Map.fetch!(args, name))

      Map.has_key?(config, "default") ->
        validate_template_arg(template, name, config, Map.fetch!(config, "default"))

      truthy?(config["required"]) ->
        {:error,
         Tool.error(:invalid_args, "missing required workflow template argument", %{
           template_id: template.template_id,
           argument: name
         })}

      true ->
        {:ok, ""}
    end
  end

  defp validate_template_arg(template, name, config, value) do
    type = template_arg_type(config)

    if template_arg_type?(value, type) do
      {:ok, value}
    else
      {:error,
       Tool.error(:invalid_args, "workflow template argument has the wrong type", %{
         template_id: template.template_id,
         argument: name,
         expected: type
       })}
    end
  end

  defp template_arg_type(config), do: field(config, "type", "string")

  defp template_arg_type?(_value, "any"), do: true
  defp template_arg_type?(value, "string"), do: is_binary(value)
  defp template_arg_type?(value, "integer"), do: is_integer(value)
  defp template_arg_type?(value, "number"), do: is_number(value)
  defp template_arg_type?(value, "boolean"), do: is_boolean(value)
  defp template_arg_type?(value, "array"), do: is_list(value)
  defp template_arg_type?(value, "object"), do: is_map(value)

  defp render_template_value(value, bindings) when is_binary(value) do
    placeholders =
      @placeholder
      |> Regex.scan(value, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    missing = Enum.reject(placeholders, &Map.has_key?(bindings, &1))

    if missing == [] do
      rendered =
        Regex.replace(@placeholder, value, fn _match, name ->
          template_arg_to_string(Map.fetch!(bindings, name))
        end)

      {:ok, rendered}
    else
      {:error,
       Tool.error(:invalid_args, "workflow template has unresolved placeholders", %{
         missing: missing
       })}
    end
  end

  defp render_template_value(values, bindings) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case render_template_value(value, bindings) do
        {:ok, rendered} -> {:cont, {:ok, acc ++ [rendered]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp render_template_value(values, bindings) when is_map(values) do
    values
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case render_template_value(value, bindings) do
        {:ok, rendered} -> {:cont, {:ok, Map.put(acc, key, rendered)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp render_template_value(value, _bindings), do: {:ok, value}

  defp template_arg_to_string(value) when is_binary(value), do: value

  defp template_arg_to_string(value) when is_number(value) or is_boolean(value),
    do: to_string(value)

  defp template_arg_to_string(value), do: Jason.encode!(value)

  defp template_metadata(template) do
    template
    |> Map.take([
      :id,
      :template_id,
      :version,
      :name,
      :description,
      :skill,
      :scope,
      :source,
      :path,
      :short_path,
      :parameters
    ])
    |> stringify_keys()
  end

  defp template_warning(skill, path, message, details) do
    %{
      "kind" => "invalid_workflow_template",
      "skill" => skill.name,
      "path" => Path.relative_to(path, skill.dir),
      "message" => message,
      "details" => stringify_keys(details)
    }
  end

  defp skill_from(root_info, dir, skill_path, content) do
    meta = frontmatter(content)
    name = blank_to_nil(meta["name"]) || Path.basename(dir)
    description = blank_to_nil(meta["description"]) || fallback_description(content)

    %{
      name: name,
      description: description,
      scope: root_info.scope,
      source: root_info.source,
      root: root_info.path,
      dir: dir,
      path: skill_path,
      short_path: "#{root_info.scope}:#{Path.basename(dir)}/SKILL.md",
      precedence: root_info.precedence,
      disable_model_invocation: truthy?(meta["disable-model-invocation"])
    }
  end

  defp resolve_collisions(candidates) do
    groups = Enum.group_by(candidates, & &1.name)

    {skills, warnings} =
      groups
      |> Enum.map(fn {name, matches} ->
        sorted = Enum.sort_by(matches, &{&1.precedence, &1.path})
        [selected | shadowed] = sorted

        warning =
          if shadowed == [] do
            nil
          else
            %{
              "name" => name,
              "selected" => selected.short_path,
              "shadowed" => Enum.map(shadowed, & &1.short_path)
            }
          end

        {Map.drop(selected, [:precedence]), warning}
      end)
      |> Enum.sort_by(fn {skill, _warning} -> skill.name end)
      |> Enum.unzip()

    %{skills: skills, warnings: Enum.reject(warnings, &is_nil/1)}
  end

  defp repo_root(workspace) do
    workspace = Path.expand(workspace)

    workspace
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.reduce_while(nil, fn dir, _ ->
      cond do
        File.dir?(Path.join(dir, ".git")) -> {:halt, dir}
        dir == Path.dirname(dir) -> {:halt, workspace}
        true -> {:cont, nil}
      end
    end)
  end

  defp user_home(opts),
    do: Keyword.get(opts, :user_home) || System.get_env("HOME") || System.user_home!()

  defp global_skills_dir(opts),
    do: Keyword.get(opts, :pixir_home, Paths.global_root()) |> Path.join("skills")

  # ── file loading / rendering ─────────────────────────────────────────────

  defp confine(root, path) do
    rel = default_rel(path)
    abs = Path.expand(rel, root)

    if abs == root or String.starts_with?(abs, root <> "/") do
      {:ok, abs}
    else
      {:error,
       Tool.error(:outside_workspace, "skill path escapes the skill directory", %{path: path})}
    end
  end

  defp read_file(abs_path, name, rel_path) do
    case File.read(abs_path) do
      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        {:error, Tool.error(:not_found, "skill file not found", %{name: name, path: rel_path})}

      {:error, reason} ->
        {:error, Tool.error(:read_failed, "could not read skill file", %{reason: reason})}
    end
  end

  defp normalize_rel(nil), do: "SKILL.md"
  defp normalize_rel(""), do: "SKILL.md"
  defp normalize_rel(path), do: path |> Path.expand("/") |> Path.relative_to("/")

  defp default_rel(nil), do: "SKILL.md"
  defp default_rel(""), do: "SKILL.md"
  defp default_rel(path), do: path

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        atom_key = String.to_existing_atom(key)
        Map.get(map, atom_key, default)
    end
  rescue
    ArgumentError -> Map.get(map, key, default)
  end

  defp field(map, key, default) when is_map(map), do: Map.get(map, key, default)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(values) when is_list(values), do: Enum.map(values, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  defp attr(nil), do: ""

  defp attr(value) do
    text(value)
    |> String.replace("\"", "&quot;")
  end

  defp text(nil), do: ""

  defp text(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # ── frontmatter parsing ──────────────────────────────────────────────────

  defp frontmatter(content) do
    lines = String.split(content, "\n")

    case lines do
      ["---" | rest] ->
        rest
        |> Enum.take_while(&(&1 != "---"))
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, ":", parts: 2) do
            [key, value] -> Map.put(acc, String.trim(key), strip_value(value))
            _ -> acc
          end
        end)

      _ ->
        %{}
    end
  end

  defp strip_value(value) do
    value
    |> String.trim()
    |> String.trim("\"")
    |> String.trim("'")
  end

  defp fallback_description(content) do
    content
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) in ["", "---"]))
    |> Enum.find("", &(not String.contains?(&1, ":")))
    |> String.trim()
    |> String.trim_leading("#")
    |> String.trim()
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp truthy?(value) when is_binary(value),
    do: (value |> String.downcase() |> String.trim()) in ["true", "yes", "1"]

  defp truthy?(true), do: true
  defp truthy?(_), do: false
end
