defmodule Bureaucrat.SwaggerSlateMarkdownWriter do
  @moduledoc """
  This markdown writer integrates swagger information and outputs in a slate-friendly markdown format.
  It requires that the decoded swagger data be available via Application.get_env(:bureaucrat, :swagger),
  eg by passing it as an option to the Bureaucrat.start/1 function.

  It can also be configured with the following options, set via the `:writer_opts` argument of Bureaucrat:

  * `:plainntext`: If `false`, will not render the plaintext version of request/response examples. Defaults to `true`
  """

  alias Bureaucrat.JSON
  alias Plug.Conn

  # pipeline-able puts
  defp puts(file, string) do
    IO.puts(file, string)
    file
  end

  @doc """
  Writes a list of Plug.Conn records to the given file path.

  Each Conn should have request and response data populated,
   and the private.phoenix_controller, private.phoenix_action values set for linking to swagger.
  """
  def write(records, path) do
    {:ok, file} = File.open(path, [:write, :utf8])
    swagger = Application.get_env(:bureaucrat, :swagger)

    file
    |> write_overview(swagger)
    |> write_intro(path)
    |> write_endpoints(records, swagger)
    |> write_models(swagger)
    |> write_change_logs(path)
  end

  @doc """
  Writes the document title and api summary description.

  This corresponds to the info section of the swagger document.
  """
  def write_overview(file, swagger) do
    info = swagger["info"]

    file
    |> puts("""
    ---
    title: #{info["title"]}

    search: true
    ---

    # #{info["title"]}

    #{info["description"]}
    """)
  end

  @doc """
  Writes any information included in an intro file at the top of the output
  document.
  """
  def write_intro(file, path) do
    intro_file_path =
      [
        # /path/to/API.md -> /path/to/API_INTRO.md
        String.replace(path, ~r/\.md$/i, "_INTRO\\0"),
        # /path/to/api.md -> /path/to/api_intro.md
        String.replace(path, ~r/\.md$/i, "_intro\\0"),
        # /path/to/API -> /path/to/API_INTRO
        "#{path}_INTRO",
        # /path/to/api -> /path/to/api_intro
        "#{path}_intro"
      ]
      # which one exists?
      |> Enum.find(nil, &File.exists?/1)

    if intro_file_path do
      file
      |> puts(File.read!(intro_file_path))
    else
      file
    end
  end

  def write_change_logs(file, path) do
    change_log_file_path =
      [
        # /path/to/API.md -> /path/to/API_CHANGE_LOGS.md
        String.replace(path, ~r/\.md$/i, "_CHANGE_LOGS\\0"),
        # /path/to/api.md -> /path/to/api_CHANGE_LOGS.md
        String.replace(path, ~r/\.md$/i, "_change_logs\\0"),
        # /path/to/API -> /path/to/API_CHANGE_LOGS
        "#{path}_CHANGE_LOGS",
        # /path/to/api -> /path/to/api_CHANGE_LOGS
        "#{path}_change_logs"
      ]
      # which one exists?
      |> Enum.find(nil, &File.exists?/1)

    if change_log_file_path do
      file
      |> puts("""

      # Changelog
      """)
      |> puts(sort_change_logs(File.read!(change_log_file_path)))
    else
      file
    end
  end

  @doc """
  Sorts changelog entries by date descending so the newest changes appear first.

  Each entry is a `## <date>` section. Entries whose heading isn't an ISO-8601
  date keep their relative order and are appended after the dated ones.
  """
  def sort_change_logs(content) do
    {dated, undated} =
      content
      |> String.split(~r/^(?=## )/m, trim: true)
      |> Enum.map(fn section -> {change_log_date(section), String.trim_trailing(section)} end)
      |> Enum.split_with(fn {date, _section} -> date != nil end)

    dated_sections =
      dated
      |> Enum.sort_by(fn {date, _section} -> date end, {:desc, Date})
      |> Enum.map(fn {_date, section} -> section end)

    (dated_sections ++ Enum.map(undated, fn {_date, section} -> section end))
    |> Enum.join("\n\n")
  end

  defp change_log_date(section) do
    with [_, heading] <- Regex.run(~r/^##\s+(\S+)/, section),
         {:ok, date} <- Date.from_iso8601(heading) do
      date
    else
      _ -> nil
    end
  end

  @doc """
  Writes the API request/response model schemas to the given file.

  This corresponds to the definitions section of the swagger document.
  Each top level definition will be written as a table.
  Nested objects are flattened out to reduce the number of tables being produced.
  """
  def write_models(file, swagger) do
    puts(file, "# Models\n")

    swagger["definitions"]
    |> Enum.sort_by(fn {name, _schema} -> name end)
    |> Enum.each(fn definition ->
      write_model(file, swagger, definition)
    end)

    file
  end

  @doc """
  Writes a single API model schema to the given file.

  Most of the work is delegated to the write_model_properties/3 recursive function.
  A unique `model-<name>` anchor is emitted as an empty block-level `<div id>`
  just before the heading so in-doc links resolve to the model rather than to the
  identically named Endpoints section (Slate slugifies both `## <Name>` headings
  to the same id, and the first one wins). A block `<div>` is used (not an inline
  `<a>`): Redcarpet merges an inline anchor into the following heading, and the
  Slate TOC helper then clones that heading's inner-HTML into the nav, producing a
  duplicate anchor whose nav copy hijacks the link.
  """
  def write_model(file, swagger, {name, model_schema}) do
    file
    |> puts(~s(<div id="#{model_anchor(name)}"></div>\n))
    |> puts("## #{name}\n")
    |> puts("#{model_schema["description"]}\n")
    |> puts("|Property|Description|Type|Required|")
    |> puts("|--------|-----------|----|--------|")
    |> write_model_properties(swagger, model_schema)
    |> puts("")
  end

  @doc """
  Writes the fields of the given model to file.

  prefix is output before each property name to enable nested objects to be flattened.
  """
  def write_model_properties(file, swagger, model_schema, prefix \\ "") do
    ordered =
      Map.get(model_schema, "properties", [])
      |> Enum.sort_by(fn {key, _schema} -> key end)

    Enum.each(ordered, fn {property, property_details} ->
      {property_details, type} = resolve_type(swagger, property_details)
      required? = is_required(property, model_schema)

      write_model_property(
        file,
        swagger,
        "#{prefix}#{property}",
        property_details,
        type,
        required?
      )
    end)

    file
  end

  def resolve_type(swagger, %{"$ref" => schema_ref}) do
    schema_name = String.replace_prefix(schema_ref, "#/definitions/", "")
    property_details = swagger["definitions"][schema_name]
    type = schema_ref_to_link(schema_ref)
    {property_details, type}
  end

  def resolve_type(_swagger, property_details) do
    {property_details, property_details["type"]}
  end

  def write_model_property(file, swagger, property, property_details, "object", _required?) do
    write_model_properties(file, swagger, property_details, "#{property}.")
  end

  def write_model_property(file, swagger, property, property_details, "array", required?) do
    schema = property_details["items"]

    # TODO: handle arrays with inline schema
    schema_ref = if schema != nil, do: schema["$ref"], else: nil

    type =
      if schema_ref != nil, do: "array(#{schema_ref_to_link(schema_ref)})", else: "array(any)"

    write_model_property(file, swagger, property, property_details, type, required?)
  end

  def write_model_property(file, _swagger, property, property_details, type, required?) do
    description = "#{format_description(property_details["description"])}#{enum_badges(property_details)}"
    puts(file, "|#{property}|#{description}|#{type}|#{required?}|")
  end

  defp is_required(property, %{"required" => required}), do: property in required
  defp is_required(_property, _schema), do: false

  # Convert a schema reference eg, #/definitions/User to a markdown link
  def schema_ref_to_link("#/definitions/" <> type) do
    "[#{type}](##{model_anchor(type)})"
  end

  # Anchor for a model's Models-section heading. Kept unique (prefixed with
  # `model-`) so links don't resolve to a same-named Endpoints section heading,
  # which Slate would otherwise slugify to the same id and win.
  def model_anchor(name), do: "model-#{String.downcase(name)}"

  @doc """
  Populate each test record with private.swagger_tag and private.operation_id from swagger.
  """
  def tag_records(records, swagger) do
    tags_by_operation_id =
      for {_path, actions} <- swagger["paths"],
          {_action, details} <- actions do
        [first_tag | _] = details["tags"]
        {details["operationId"], first_tag}
      end
      |> Enum.into(%{})

    Enum.map(records, &tag_record(&1, tags_by_operation_id))
  end

  @doc """
  Tag a single record with swagger tag and operation_id.
  """
  def tag_record(conn, tags_by_operation_id) do
    operation_id = conn.assigns.bureaucrat_opts[:operation_id]
    Conn.put_private(conn, :swagger_tag, tags_by_operation_id[operation_id])
  end

  # Report operations are pulled out of their individual swagger tags and
  # consolidated under a single "Reports" menu section.
  @reports_path_prefix "/public/v1/reports/"
  @reports_section "Reports"

  @doc """
  Writes every API operation under a single top-level "Endpoints" section.

  Operations are grouped into menu sections (the swagger tag, or "Reports" for
  report endpoints), then rendered as `## Section` (h2) with each operation as
  `### Summary` (h3). Sections and operations are sorted alphabetically so the
  generated Slate navigation is alphabetical.
  """
  def write_endpoints(file, records, swagger) do
    puts(file, "# Endpoints\n")

    records
    |> tag_records(swagger)
    |> group_into_sections(swagger)
    |> Enum.each(fn {section, operations} ->
      puts(file, "## #{section}\n")

      Enum.each(operations, fn {details, operation_records} ->
        write_action(file, details, operation_records, swagger)
      end)
    end)

    file
  end

  @doc """
  Groups tagged records into alphabetically sorted menu sections.

  Returns `[{section, operations}]` sorted by section, where operations is
  `[{operation_details, records}]` sorted by summary. Report endpoints are
  collected under the "Reports" section regardless of their swagger tag.
  """
  def group_into_sections(records, swagger) do
    records
    |> Enum.group_by(& &1.assigns.bureaucrat_opts[:operation_id])
    |> Enum.map(fn {operation_id, operation_records} ->
      details = find_operation_by_id(swagger, operation_id)
      {section_for(details, operation_records), details, operation_records}
    end)
    |> Enum.group_by(fn {section, _details, _records} -> section end)
    |> Enum.map(fn {section, operations} ->
      sorted =
        operations
        |> Enum.map(fn {_section, details, records} -> {details, records} end)
        |> Enum.sort_by(fn {details, _records} -> details["summary"] end)

      {section, sorted}
    end)
    |> Enum.sort_by(fn {section, _operations} -> section end)
  end

  defp section_for(details, records) do
    if String.starts_with?(to_string(details["path"]), @reports_path_prefix) do
      @reports_section
    else
      List.first(records).private.swagger_tag
    end
  end

  @doc """
  Writes all examples of a given operation (Controller action) to file.
  """
  def write_action(file, details, records, swagger) do
    puts(file, "### #{details["summary"]}\n")

    # write the example(s) before params/schemas to get correct alignment in slate.
    # One success example (request + response), then each `response_only` error
    # example (response only), in source order.
    case representative_record(records) do
      nil -> file
      record -> write_example(file, record)
    end

    Enum.each(error_records(records), &write_example(file, &1))

    file
    |> puts("#{details["description"]}\n")
    |> write_request(details)
    |> write_parameters(swagger, details)
    |> write_responses(details)
  end

  # The success example: a single record per operation, never one flagged
  # `response_only`. Prefer a 2xx response and, among those, the one with the
  # largest body (most fields populated); fall back to the largest non-2xx.
  def representative_record([]), do: nil

  def representative_record(records) do
    candidates = Enum.reject(records, &response_only?/1)
    successes = Enum.filter(candidates, fn record -> record.status in 200..299 end)
    candidates = if successes == [], do: candidates, else: successes

    case candidates do
      [] -> nil
      list -> Enum.max_by(list, fn record -> byte_size(record.resp_body || "") end)
    end
  end

  # Error examples: every record explicitly flagged `response_only: true` via
  # `doc(..., response_only: true)`, rendered response-only after the success
  # example. Sorted by source line so the order is deterministic.
  defp error_records(records) do
    records
    |> Enum.filter(&response_only?/1)
    |> Enum.sort_by(fn record -> record.assigns[:bureaucrat_line] || 0 end)
  end

  defp response_only?(record) do
    record.assigns
    |> Map.get(:bureaucrat_opts, [])
    |> Keyword.get(:response_only, false)
  end

  @doc """
  Find the details of an API operation in swagger by operationId
  """
  def find_operation_by_id(swagger, operation_id) do
    Enum.flat_map(swagger["paths"], fn {path, actions} ->
      Enum.map(actions, fn {action, details} ->
        details
        |> Map.put("action", action)
        |> Map.put("path", path)
      end)
    end)
    |> Enum.find(fn details ->
      details["operationId"] == operation_id
    end)
  end

  @doc """
  Writes the request method and path
  """
  def write_request(file, %{"action" => action, "path" => path}) do
    file
    |> puts("#### Request\n")
    |> puts("`#{String.upcase(action)} #{path}`")
  end

  @doc """
  Writes the parameters table for given swagger operation to file.

  Uses the vendor extension "x-example" to provide example of each parameter.
  TODO: detailed schema validation rules aren't shown yet (min/max/regex/etc...)
  """
  def write_parameters(file, swagger, _ = %{"parameters" => params})
      when length(params) > 0 or map_size(params) > 0 do
    params = Enum.flat_map(params, &expand_body_param(swagger, &1))

    file
    |> puts("#### Parameters\n")
    |> puts("| Parameter   | Description | In |Type      | Required | Default | Example |")
    |> puts("|-------------|-------------|----|----------|----------|---------|---------|")

    Enum.each(Enum.sort_by(params, & &1["name"]), fn param ->
      badges = enum_badges(param)

      enriched_param =
        swagger
        |> resolve_schema_type(param)
        |> Map.update("description", badges, &"#{format_description(&1)}#{badges}")

      content =
        ["name", "description", "in", "type", "required", "default", "x-example"]
        |> Enum.map(&enriched_param[&1])
        |> Enum.map(&encode_parameter_table_cell/1)
        |> Enum.join("|")

      puts(file, "|#{content}|")
    end)

    puts(file, "")
  end

  def write_parameters(file, _swagger, _), do: file

  # A body param wraps the whole request in one swagger param (named `payload`),
  # but no such field exists on the wire. Show the body schema's top-level
  # fields as the parameters instead.
  defp expand_body_param(swagger, %{"in" => "body", "schema" => schema} = param) do
    {definition, _type} = resolve_type(swagger, schema)
    properties = Map.get(definition || %{}, "properties", %{})

    if properties == %{} do
      [param]
    else
      Enum.map(properties, fn {name, property_details} ->
        {resolved_details, type} = resolve_type(swagger, property_details)

        resolved_details
        |> Map.merge(%{
          "name" => name,
          "in" => "body",
          "type" => body_field_type(type, resolved_details),
          "required" => is_required(name, definition)
        })
      end)
    end
  end

  defp expand_body_param(_swagger, param), do: [param]

  defp body_field_type("array", details) do
    case details["items"] do
      %{"$ref" => ref} -> "array(#{schema_ref_to_link(ref)})"
      %{"type" => type} -> "array(#{type})"
      _ -> "array(any)"
    end
  end

  defp body_field_type(type, _details), do: type

  def resolve_schema_type(swagger, %{"schema" => schema} = param) do
    {_def, type} = resolve_type(swagger, schema)
    Map.put(param, "type", type)
  end

  def resolve_schema_type(_swagger, param), do: param

  # Encode parameter table cell values as strings, using json library to convert lists/maps
  defp encode_parameter_table_cell(param) when is_map(param) or is_list(param),
    do: JSON.encode!(param)

  defp encode_parameter_table_cell(param), do: to_string(param)

  # A description may enumerate allowed values as bullets, each prefixed with "• "
  # (see the public API swagger schemas). Render those as a real HTML `<ul>` list
  # so they display as bullets instead of one run-on line; a table cell can't hold
  # Markdown list syntax, so raw HTML is the only option. Text before the first
  # bullet (intro) is emitted before the list. A bullet item ends at its first
  # newline, so text on the lines after the last bullet is emitted after the list,
  # not inside the last item. Any `<br>` separators around the bullets are
  # dropped — the list markup provides the line breaks.
  defp format_description(nil), do: ""

  defp format_description(description) do
    if String.contains?(description, "•") do
      [intro | items] =
        description
        |> String.replace("<br>", "")
        |> String.split("•")

      {front, [last]} = Enum.split(items, -1)

      {last, trailing} =
        case String.split(last, "\n", parts: 2) do
          [item] -> {item, ""}
          [item, rest] -> {item, rest |> flatten_newlines() |> String.trim()}
        end

      list = Enum.map_join(front ++ [last], &"<li>#{&1 |> flatten_newlines() |> String.trim()}</li>")

      "#{intro |> flatten_newlines() |> String.trim_trailing()}<ul>#{list}</ul>#{trailing}"
    else
      flatten_newlines(description)
    end
  end

  # A markdown table row must be a single line, so a cell can't hold raw newlines:
  # render paragraph breaks as <br> and collapse remaining newlines to spaces.
  defp flatten_newlines(text) do
    text
    |> String.replace(~r/\n{2,}/, "<br>")
    |> String.replace("\n", " ")
  end

  # Render a field's allowed enum values as inline badges under its description.
  # Enum values live directly on the field (query params, model properties), on its
  # array `items` (array fields), or on its `schema` (body params).
  defp enum_badges(details) do
    values =
      details["enum"] || get_in(details, ["items", "enum"]) ||
        get_in(details, ["schema", "enum"]) || get_in(details, ["schema", "items", "enum"])

    case values do
      nil -> ""
      values -> "<br>" <> Enum.map_join(values, " ", &~s(<span class="enum-badge">#{&1}</span>))
    end
  end

  @doc """
  Writes the responses table for given swagger operation to file.

  Swagger only allows a single description per status code, which can be limiting
   when trying to describe all possible error responses.  To work around this, add
   markdown links into the description.
  """
  def write_responses(file, swagger_operation) do
    file
    |> puts("#### Responses\n")
    |> puts("| Status | Description | Schema |")
    |> puts("|--------|-------------|--------|")

    Enum.each(swagger_operation["responses"], fn {status, response} ->
      ref = get_in(response, ["schema", "$ref"])
      schema = if ref, do: schema_ref_to_link(ref), else: ""
      puts(file, "|#{status} | #{response["description"]} | #{schema}|")
    end)
  end

  @doc """
  Writes a single request/response example to file
  """
  def write_example(file, record) do
    path =
      case record.query_string do
        "" -> record.request_path
        str -> "#{record.request_path}?#{str}"
      end

    plaintext = Keyword.get(config(), :plaintext, true)
    response_only = response_only?(record)

    # Header (the doc description) always renders above the example.
    puts(file, "> #{record.assigns.bureaucrat_desc}\n")

    # Request with path and headers — omitted for response-only examples.
    if plaintext and not response_only do
      file
      |> puts("```plaintext")
      |> puts("#{record.method} #{path}")
      |> write_headers(record.req_headers)
      |> puts("```\n")
    end

    # Request Body if applicable — omitted for response-only examples.
    unless response_only or record.body_params == %{} do
      file
      |> puts("```json")
      |> puts("#{JSON.encode!(deep_sort_json(record.body_params), pretty: true)}")
      |> puts("```\n")
    end

    # Response with status and headers
    file
    |> puts("> Response\n")

    if plaintext do
      file
      |> puts("```plaintext")
      |> puts("#{record.status}")
      |> write_headers(record.resp_headers)
      |> puts("```\n")
    end

    # Response body
    file
    |> puts("```json")
    |> puts("#{format_resp_body(record.resp_body)}")
    |> puts("```\n")
  end

  @doc """
  Write the list of request/response headers
  """
  def write_headers(file, headers) do
    Enum.each(headers, fn {header, value} ->
      puts(file, "#{header}: #{value}")
    end)

    file
  end

  @doc """
  Pretty-print a JSON response, handling body correctly
  """
  def format_resp_body(string) do
    case string do
      "" -> ""
      _ -> string |> JSON.decode!() |> deep_sort_json() |> JSON.encode!(pretty: true)
    end
  end

  @doc """
  Recursively sorts object keys so rendered JSON examples are alphabetical.

  Maps become `Jason.OrderedObject`s (the configured JSON library is Jason) to
  preserve key order through encoding; lists are mapped element-wise.
  """
  # Only plain JSON objects get key-sorted. Structs (e.g. Plug.Upload in a
  # file-upload body) pass through untouched so their own Jason encoder is used,
  # matching how the body was encoded before sorting was introduced.
  def deep_sort_json(%_{} = struct), do: struct

  def deep_sort_json(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> {key, deep_sort_json(value)} end)
    |> Jason.OrderedObject.new()
  end

  def deep_sort_json(list) when is_list(list), do: Enum.map(list, &deep_sort_json/1)
  def deep_sort_json(value), do: value

  defp config, do: Application.get_env(:bureaucrat, :writer_opts, [])
end
