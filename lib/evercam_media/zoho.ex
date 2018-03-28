defmodule EvercamMedia.Zoho do
  alias EvercamMedia.Util
  require Logger

  @zoho_url System.get_env["ZOHO_URL"]
  @zoho_auth_token System.get_env["ZOHO_AUTH_TOKEN"]

  def get_camera(camera_exid) do
    url = "#{@zoho_url}json/CustomModule4/searchRecords?authtoken=#{@zoho_auth_token}&scope=crmapi&newFormat=2&criteria=(Evercam%20ID:#{camera_exid})"
    headers = ["Accept": "application/offset+octet-stream", "Content-Type": "multipart/form-data"]
    response = HTTPoison.get(url, headers) |> elem(1)

    case response.status_code do
      200 ->
        json_response = Poison.decode!(response.body)
        case Util.deep_get(json_response, ["response", "nodata", "code"], nil) do
          "4422" -> {:nodata, Util.deep_get(json_response, ["response", "nodata", "message"], "")}
          _ -> {:ok, Util.deep_get(json_response, ["response", "result", "CustomModule4", "row", "FL"], "")}
        end
      _ -> {:error, response}
    end
  end

  def insert_camera(cameras) do
    url = "#{@zoho_url}xml/CustomModule4/insertRecords?authtoken=#{@zoho_auth_token}&scope=crmapi&newFormat=2"
    headers = ["Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded"]
    camera_xml = create_request_xml(cameras, "xmlData=<Cameras>", 1)
    camera_xml = "#{camera_xml}</Cameras>"

    case HTTPoison.post!(url, camera_xml, headers) do
      %HTTPoison.Response{body: body} -> {:ok, body}
      _ -> {:error}
    end
  end

  def update_camera(cameras, id) do
    url = "#{@zoho_url}xml/CustomModule4/updateRecords?authtoken=#{@zoho_auth_token}&id=#{id}&scope=crmapi&newFormat=2"
    headers = ["Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded"]
    camera_xml = create_request_xml(cameras, "xmlData=<Cameras>", 1)
    camera_xml = "#{camera_xml}</Cameras>"

    case HTTPoison.post!(url, camera_xml, headers) do
      %HTTPoison.Response{body: body} -> {:ok, body}
      _ -> {:error}
    end
  end

  def get_contact(email) do
    url = "#{@zoho_url}json/Contacts/searchRecords?authtoken=#{@zoho_auth_token}&scope=crmapi&newFormat=2&criteria=(Email:#{email})"
    headers = ["Accept": "application/offset+octet-stream", "Content-Type": "multipart/form-data"]
    response = HTTPoison.get(url, headers) |> elem(1)

    case response.status_code do
      200 ->
        json_response = Poison.decode!(response.body)
        case Util.deep_get(json_response, ["response", "nodata", "code"], nil) do
          "4422" -> {:nodata, Util.deep_get(json_response, ["response", "nodata", "message"], "")}
          _ ->
            zoho_contact =
              case Util.deep_get(json_response, ["response", "result", "Contacts", "row"]) do
                %{"FL" => contact} -> contact
                contacts -> contacts |> List.first |> Util.deep_get(["FL"])
              end
            {:ok, zoho_contact}
        end
      _ -> {:error, response}
    end
  end

  def insert_contact(cameras) do
    url = "#{@zoho_url}xml/Contacts/insertRecords?authtoken=#{@zoho_auth_token}&scope=crmapi&newFormat=2"
    headers = ["Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded"]
    camera_xml = create_request_xml(cameras, "xmlData=<Cameras>", 1)
    camera_xml = "#{camera_xml}</Cameras>"

    case HTTPoison.post!(url, camera_xml, headers) do
      %HTTPoison.Response{body: body} -> {:ok, body}
      _ -> {:error}
    end
  end

  defp create_request_xml([camera | rest], camera_xml, index) do
    url_to_nvr = "http://#{Camera.host(camera, "external")}:#{Camera.get_nvr_port(camera)}"
    evercam_type =
      case camera.owner.username do
        "smartcities" -> "Smart Cities"
        _ -> "Construction"
      end
    camera_xml = "#{camera_xml}<row no=\"#{index}\"><FL val=\"Camera Name\">#{camera.name}</FL><FL val=\"Evercam ID\">#{camera.exid}</FL>
      <FL val=\"Evercam Type\">#{evercam_type}</FL><FL val=\"URL to NVR\">#{url_to_nvr}</FL><FL val=\"Passwords\">#{Camera.password(camera)}</FL></row>"

    create_request_xml(rest, camera_xml, index + 1)
  end
  defp create_request_xml([], camera_xml, _index), do: camera_xml
end
