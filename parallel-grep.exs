defmodule ParallelGrep do
        def run do
                IO.puts("ParallelGrep.run")
        end

        def ls_r(path \\ ".") do
                cond do
                        File.regular?(path) -> [path]
                        File.dir?(path) ->
                                File.ls!(path)
                                |> Enum.map(&Path.join(path, &1))
                                |> Enum.map(&ls_r/1)
                                |> Enum.concat
                                true -> []
                end
        end
end

defmodule FileGrepper do
        def grep_file(file_path, regex, pid) do
                File.stream!(file_path)
                |> Stream.filter(line_matches(regex))
                |> Stream.map( &send_line(pid, &1) )
                |> Stream.run
        end

        defp line_matches(regex) do
                fn(line) ->
                        {:ok, regex_compiled} = Regex.compile(regex, [:caseless])
                        Regex.match?(regex_compiled, line)
                end
        end

        defp send_line(pid, line) do
                send(pid, {:line, line})
        end
end

defmodule FileGrepper.Process do
        def start(pid, regex) do
                send( pid, {:next, self()} )
                loop(pid, regex)
        end

        defp loop(pid, regex) do
                receive do
                        {:file, file_path} ->
                                FileGrepper.grep_file(file_path, regex, pid)
                                send( pid, {:next, self()} )

                                loop(pid, regex)
                        :finish ->
                                send(pid, :finish)
                        _message ->
                                loop(pid, regex)
                end
        end
end

defmodule ProcessManager do
        @max_processes 100

        def start(file_list, regex) do
                manager = self()
                process_list =
                        Enum.map(1..@max_processes, fn(_) ->
                                spawn(fn ->
                                        FileGrepper.Process.start(manager, regex)
                                end)
                        end)

                loop(file_list, process_list)
        end

        defp loop([], process_list) do
                Enum.each(process_list, fn(pid) ->
                        send(pid, :finish)
                end)

                loop_finish( length(process_list) )
        end

        defp loop(full_list = [file_path | file_list], process_list) do
                receive do
                        {:next, pid} ->
                                send(pid, {:file, file_path})
                                loop(file_list, process_list)
                        {:line, line} ->
                                IO.write line
                                loop(full_list, process_list)
                        message ->
                                IO.puts("Unknown message: #{message}")
                                loop(full_list, process_list)
                end
        end

        defp loop_finish(0) do
                :ok
        end

        defp loop_finish(n) do
                receive do
                        {:line, line} ->
                                IO.write line
                                loop_finish(n)
                        :finish ->
                                loop_finish(n - 1)
                        _message ->
                                loop_finish(n)
                end
        end
end

[regex | _] = System.argv

file_list = ParallelGrep.ls_r()

ProcessManager.start(file_list, regex)