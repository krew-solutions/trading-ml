let parse (s : string) : int64 =
  try
    Scanf.sscanf s "%d-%d-%dT%d:%d:%d" (fun y mo d h mi se ->
        let y = if mo <= 2 then y - 1 else y in
        let era = (if y >= 0 then y else y - 399) / 400 in
        let yoe = y - (era * 400) in
        let m' = if mo > 2 then mo - 3 else mo + 9 in
        let doy = (((153 * m') + 2) / 5) + d - 1 in
        let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
        let days = (era * 146097) + doe - 719468 in
        Int64.(add (mul (of_int days) 86400L) (of_int ((h * 3600) + (mi * 60) + se))))
  with _ -> ( try Int64.of_string s with _ -> 0L)
