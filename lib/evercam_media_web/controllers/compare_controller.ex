defmodule EvercamMediaWeb.CompareController do
  use EvercamMediaWeb, :controller
  alias EvercamMediaWeb.CompareView
  alias EvercamMedia.Util
  alias EvercamMedia.TimelapseRecording.S3

  def index(conn, %{"id" => camera_exid}) do
    current_user = conn.assigns[:current_user]
    camera = Camera.get_full(camera_exid)

    with :ok <- ensure_camera_exists(camera, camera_exid, conn),
         :ok <- ensure_can_list(current_user, camera, conn)
    do
      compare_archives = Compare.get_by_camera(camera.id)
      render(conn, CompareView, "index.json", %{compares: compare_archives})
    end
  end

  def show(conn, %{"id" => camera_exid, "compare_id" => compare_id}) do
    current_user = conn.assigns[:current_user]
    camera = Camera.get_full(camera_exid)

    with :ok <- ensure_camera_exists(camera, camera_exid, conn),
         :ok <- deliver_content(conn, camera_exid, compare_id),
         :ok <- ensure_can_list(current_user, camera, conn)
    do
      case Compare.by_exid(camera_exid) do
        nil ->
          render_error(conn, 404, "Compare archive '#{compare_id}' not found!")
        compare_archive ->
          render(conn, CompareView, "show.json", %{compare: compare_archive})
      end
    end
  end

  def create(conn, %{"id" => camera_exid} = params) do
    current_user = conn.assigns[:current_user]
    camera = Camera.get_full(camera_exid)

    with :ok <- authorized(conn, current_user),
         :ok <- ensure_camera_exists(camera, camera_exid, conn)
    do
      compare_params = %{
        camera_id: camera.id,
        name: params["name"],
        before_date: convert_to_datetime(params["before"]),
        after_date: convert_to_datetime(params["after"]),
        embed_code: params["embed"]
      }
      |> add_parameter("field", :create_animation, params["create_animation"])
      changeset = Compare.changeset(%Compare{}, compare_params)

      case Repo.insert(changeset) do
        {:ok, compare} ->
          created_compare =
            compare
            |> Repo.preload(:camera)
            |> Repo.preload([camera: :owner])
          spawn fn -> export_image(camera_exid, String.to_integer(params["before"]), params["before_image"]) end
          spawn fn -> export_image(camera_exid, String.to_integer(params["after"]), params["after_image"]) end
          spawn fn -> create_animated(params["create_animation"], camera_exid, compare.exid, params["before_image"], params["after_image"]) end
          render(conn |> put_status(:created), CompareView, "show.json", %{compare: created_compare})
        {:error, changeset} ->
          render_error(conn, 400, Util.parse_changeset(changeset))
      end
    end
  end

  defp get_content_type("gif"), do: "image/gif"
  defp get_content_type("mp4"), do: "video/mp4"

  defp export_image(camera_exid, timestamp, image_base64) do
    decoded_image = decode_image(image_base64)
    S3.save(camera_exid, timestamp, decoded_image, "compare", [acl: :public_read])
  end

  defp create_animated(animation, camera_exid, compare_id, before_image, after_image) when animation in [true, "true"] do
    root = "#{Application.get_env(:evercam_media, :storage_dir)}/#{compare_id}/"
    File.mkdir_p(root)
    File.write("#{root}before_image.jpg", decode_image(before_image))
    File.write("#{root}after_image.jpg", decode_image(after_image))

    evercam_logo = Path.join(Application.app_dir(:evercam_media), "priv/static/images/evercam-logo.png")
    animated_file = "#{root}#{compare_id}.gif"
    comm_resize_before = "ffmpeg -i #{root}before_image.jpg -s 1280x720 #{root}before_image_resize.jpg"
    comm_resize_after = "ffmpeg -i #{root}after_image.jpg -s 1280x720 #{root}after_image_resize.jpg"
    logo_comm = "convert #{root}temp.gif -gravity SouthEast -geometry +0+0 null: #{evercam_logo} -layers Composite #{animated_file}"
    animation_comm = "convert #{root}after_image_resize.jpg #{root}before_image_resize.jpg -write mpr:stack -delete 0--1 mpr:stack'[1]' \\( mpr:stack'[0]' -set delay 3 -crop 4x0 -reverse \\) mpr:stack'[0]' \\( mpr:stack'[1]' -set delay 4 -crop 8x0 \\) -set delay 2 -loop 0 #{root}temp.gif"
    mp4_command = "ffmpeg -i #{animated_file} #{root}#{compare_id}.mp4"
    command = "#{comm_resize_before} && #{comm_resize_after} && #{animation_comm} && #{logo_comm} && #{mp4_command}"

    case Porcelain.shell(command).out do
      "" ->
        gif_content = File.read!(animated_file)
        mp4_content = File.read!("#{root}#{compare_id}.mp4")
        upload_path = "#{camera_exid}/compares/#{compare_id}"
        S3.do_save("#{upload_path}.gif", gif_content, [content_type: "image/gif", acl: :public_read])
        S3.do_save("#{upload_path}.mp4", mp4_content, [acl: :public_read])
      _ -> :nothing
    end
    File.rm_rf(root)
  end
  defp create_animated(_animation, _camera_exid, _compare_id, _before_image, _after_image), do: :nothing

  defp decode_image(image_base64) do
    image_base64
    |> String.replace_leading("data:image/jpeg;base64,", "")
    |> Base.decode64!
  end

  defp ensure_camera_exists(nil, exid, conn) do
    render_error(conn, 404, "Camera '#{exid}' not found!")
  end
  defp ensure_camera_exists(_camera, _exid, _conn), do: :ok

  defp ensure_can_list(current_user, camera, conn) do
    if current_user && Permission.Camera.can_list?(current_user, camera) do
      :ok
    else
      render_error(conn, 401, "Unauthorized.")
    end
  end

  defp deliver_content(conn, camera_exid, compare_id) do
    format =
      String.split(compare_id, ".")
      |> Enum.filter(fn(n) -> n == "gif" || n == "mp4" end)
      |> List.first

    case format do
      nil -> :ok
      extension -> load_animation(conn, camera_exid, String.replace(compare_id, [".gif", ".mp4"], ""), extension)
    end
  end

  defp load_animation(conn, camera_exid, compare_id, format) do
    case S3.do_load("#{camera_exid}/compares/#{compare_id}.#{format}") do
      {:ok, response} ->
        conn
        |> put_resp_header("content-type", get_content_type(format))
        |> text(response)
      {:error, code, message} ->
        conn
        |> put_status(code)
        |> json(message)
    end
  end

  defp add_parameter(params, _field, _key, nil), do: params
  defp add_parameter(params, "field", key, value) do
    Map.put(params, key, value)
  end

  defp convert_to_datetime(value) when value in [nil, ""], do: value
  defp convert_to_datetime(value) do
    value
    |> String.to_integer
    |> Calendar.DateTime.Parse.unix!
    |> Calendar.DateTime.to_erl
    |> Calendar.DateTime.from_erl!("Etc/UTC")
  end

  defp authorized(conn, nil), do: render_error(conn, 401, "Unauthorized.")
  defp authorized(_conn, _current_user), do: :ok
end
