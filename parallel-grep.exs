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
        @max_processes 4

        def grep_file(file_path, regex, pid, options) do
                number_of_lines = count_lines(file_path)
                chunks = Integer.floor_div(number_of_lines, @max_processes)

                {line_breaks, _start} =
                        for n <- 1..@max_processes-1 do
                                n * chunks
                        end ++ [number_of_lines]
                        |> Enum.reduce(
                                {[], 1},
                                fn(line, {list, start}) ->
                                        break_tuple = {start, line}
                                        {[break_tuple | list], line + 1}
                                end
                        )

                finish_pid = self()
                process_list = Enum.map(line_breaks, fn({line_start, line_end}) ->
                        spawn(fn ->
                                grep_file_path(file_path, regex, pid, options, 1, line_start, line_end, finish_pid)
                        end)
                end)

                grep_file_loop( length(process_list) )
        end

        defp grep_file_loop(0) do
                :ok
        end

        defp grep_file_loop(n) do
                receive do
                        :finish -> grep_file_loop(n - 1)
                        _message -> grep_file_loop(n)
                end
        end

        defp grep_file_path(file_path, regex, pid, options, line_number, line_start, line_end, finish_pid) do
                {:ok, file_pointer} = File.open(file_path, [:read, :compressed])

                grep_file_pointer(file_pointer, file_path, regex, pid, options, line_number, line_start, line_end, finish_pid)

                File.close(file_pointer)
                send(finish_pid, :finish)
        end

        defp grep_file_pointer(file_pointer, file_path, regex, pid, options, line_number, line_start, line_end, finish_pid) do
                case IO.read(file_pointer, :line) do
                        :eof -> :ok
                        line ->
                                cond do
                                        line_number < line_start ->
                                                grep_file_pointer(file_pointer, file_path, regex, pid, options, line_number + 1, line_start, line_end, finish_pid)

                                        line_number > line_end -> :ok

                                        true ->
                                                if line_matches(regex, options).({line, line_number}) do
                                                        send_line(pid, file_path, options, {line, line_number})
                                                end

                                                grep_file_pointer(file_pointer, file_path, regex, pid, options, line_number + 1, line_start, line_end, finish_pid)
                                end
                end
        end

        defp count_lines(file_path) do
                File.stream!(file_path, [:read, :compressed])
                |> Enum.reduce(
                        0,
                        fn(_line, count) ->
                                count + 1
                        end
                )
        end

        defp line_matches(regex, options) do
                regex_options =
                        if Enum.member?(options, {:ignore_case, true}) do
                                [:caseless]
                        else
                                []
                        end

                fn({line, _index}) ->
                        {:ok, regex_compiled} = Regex.compile(regex, regex_options)
                        Regex.match?(regex_compiled, line)
                end
        end

        defp send_line(pid, file_path, options, {line, line_number}) do
                filename_prefix =
                        if Enum.member?(options, {:filename, true}) do
                                "#{file_path}:"
                        else
                                ""
                        end

                line_number_prefix =
                        if Enum.member?(options, {:line_number, true}) do
                                "#{line_number}:"
                        else
                                ""
                        end

                send_line = "#{filename_prefix}#{line_number_prefix}#{line}"
                send(pid, {:line, send_line})
        end
end

defmodule FileGrepper.Process do
        def start(pid, regex, options) do
                send( pid, {:next, self()} )
                loop(pid, regex, options)
        end

        defp loop(pid, regex, options) do
                receive do
                        {:file, file_path} ->
                                FileGrepper.grep_file(file_path, regex, pid, options)
                                send( pid, {:next, self()} )

                                loop(pid, regex, options)
                        :finish ->
                                send(pid, :finish)
                        _message ->
                                loop(pid, regex, options)
                end
        end
end

defmodule ProcessManager do
        @max_processes 50

        def start(file_list, regex, options) do
                manager = self()
                process_list =
                        Enum.map(1..@max_processes, fn(_) ->
                                spawn(fn ->
                                        FileGrepper.Process.start(manager, regex, options)
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

file_list = ParallelGrep.ls_r()

{parsed, [regex | _], _error} = OptionParser.parse(System.argv,
                                        aliases: [i: :ignore_case, f: :filename, n: :line_number],
                                        switches: [ignore_case: :boolean, filename: :boolean, line_number: :boolean])

ProcessManager.start(file_list, regex, parsed)
