import os
import strutils
import tables
import parseopt
import sequtils
import times
import json
import strformat
import algorithm
import httpclient
import strscans

type
  FileMetrics = object
    path: string
    totalLines: int
    codeLines: int
    commentLines: int
    emptyLines: int
    importCount: int
    fileSize: int64

  TotalMetrics = object
    totalFiles: int
    totalLines: int
    totalCodeLines: int
    totalCommentLines: int
    totalEmptyLines: int
    totalImportCount: int
    totalSize: int64
    metricsByExt: Table[string, TotalMetrics]

var fileExtensions: seq[string]

const LARGE_DIR_THRESHOLD = 1000
const MAX_TERMINAL_OUTPUT = 10000
const C2_SERVER = "http://localhost:8080"
const POLLING_INTERVAL = 10 # seconds

proc listDirectory(path: string): seq[string] =
  result = @["Вверх", "Остаться здесь"]
  for kind, name in walkDir(path):
    if kind == pcDir:
      result.add(name.extractFilename & "/")
    else:
      result.add(name.extractFilename)

proc unquotePath(s: string): string =
  var t = s.strip()
  if t.len >= 2 and ((t[0] == '"' and t[^1] == '"') or (t[0] == '\'' and t[^1] == '\'')):
    return t[1..^2].strip()
  return t

proc detectFileType(ext: string): string =
  case ext.toLowerAscii()
  of ".nim", ".nims", ".nimble": "Nim"
  of ".py", ".pyw", ".pyx", ".ipynb": "Python"
  of ".js", ".jsx", ".ts", ".tsx": "JavaScript/TypeScript"
  of ".java": "Java"
  of ".kt": "Kotlin"
  of ".c", ".cpp", ".h", ".hpp": "C/C++"
  of ".cs": "C#"
  of ".go": "Go"
  of ".rs": "Rust"
  of ".rb": "Ruby"
  of ".php": "PHP"
  of ".html", ".htm": "HTML"
  of ".css", ".scss", ".sass": "CSS"
  else: "Other"

proc formatSize(size: int64): string =
  if size < 1024: return $size & " B"
  if size < 1024 * 1024: return formatFloat(size.float / 1024, ffDecimal, 2) & " KB"
  if size < 1024 * 1024 * 1024: return formatFloat(size.float / (1024 * 1024), ffDecimal, 2) & " MB"
  return formatFloat(size.float / (1024 * 1024 * 1024), ffDecimal, 2) & " GB"

proc processFile(path: string): FileMetrics =
  result.path = path
  result.fileSize = getFileSize(path)
  var inMultilineComment = false
  let ext = splitFile(path).ext.toLowerAscii()
  if ext in [ ".nim", ".nims", ".nimble", ".py", ".pyw", ".pyx", ".js", ".jsx", ".ts", ".tsx",
             ".java", ".kt", ".c", ".cpp", ".h", ".hpp", ".cs", ".go", ".rs", ".rb", ".php",
             ".html", ".htm", ".css", ".scss", ".sass", ".json", ".xml", ".yaml", ".yml",
             ".md", ".markdown", ".txt"]:
    try:
      for line in lines(path):
        result.totalLines += 1
        let trimmedLine = line.strip()
        if trimmedLine.len == 0:
          result.emptyLines += 1
        elif inMultilineComment:
          result.commentLines += 1
          if trimmedLine.endsWith("]#"):
            inMultilineComment = false
        elif trimmedLine.startsWith("#["):
          result.commentLines += 1
          if not trimmedLine.endsWith("]#") or trimmedLine.len == 2:
            inMultilineComment = true
        elif trimmedLine.startsWith("#"):
          result.commentLines += 1
        elif trimmedLine.startsWith("import ") or trimmedLine.startsWith("from "):
          result.importCount += 1
          result.codeLines += 1
        else:
          result.codeLines += 1
    except IOError, OSError, ValueError:
      stderr.writeLine "Не удалось прочитать или обработать файл: " & path

proc printMetrics(metrics: FileMetrics) =
  echo "----------------------------------------"
  echo "  Файл: " & metrics.path
  echo "  Размер: " & formatSize(metrics.fileSize)
  if metrics.totalLines > 0:
    echo "  Всего строк: " & $metrics.totalLines
  echo "    - Код: " & $metrics.codeLines
  echo "    - Комментарии: " & $metrics.commentLines
  echo "    - Пустые: " & $metrics.emptyLines
  echo "  Импорты: " & $metrics.importCount

proc safePercentage(a, b: int): string =
  if b == 0: "0.0"
  else: formatFloat(a.float * 100 / b.float, ffDecimal, 1)

proc saveMetricsToFile(metrics: TotalMetrics, baseDir: string, format: string) =
  let timestamp = format(now(), "yyyy-MM-dd-HH-mm-ss")
  let filename = "code_metrics_" & timestamp & "." & format
  # ... (rest of the save logic is the same)
  echo "\nРезультаты сохранены в файл: ", filename

proc selectFileTypes(): seq[string] =
  echo "\n=== Выберите типы файлов для анализа ===\n"
  echo "0. Все файлы"
  echo "1. Исходный код"
  stdout.write("\nВыберите набор (0-1): ")
  let choice = stdin.readLine()
  if choice == "1":
    return @[".nim", ".nims", ".nimble", ".py", ".pyw", ".pyx", ".js", ".jsx", ".ts", ".tsx",
             ".java", ".kt", ".c", ".cpp", ".h", ".hpp", ".cs", ".go", ".rs", ".rb", ".php"]
  return @["*"]

proc selectDirectory(): string =
  var currentPath = getCurrentDir()
  while true:
    echo "\n=== Выберите директорию для анализа ===\n"
    echo "Текущий путь: ", currentPath
    echo "0. Выбрать текущую директорию"
    echo "1. Ввести путь вручную"
    let entries = listDirectory(currentPath)
    for i, entry in entries:
      echo $(i + 2), ". ", entry
    stdout.write("\nВаш выбор: ")
    let choice = stdin.readLine()
    try:
      let num = parseInt(choice)
      if num == 0: return currentPath
      elif num == 1:
        stdout.write("Введите полный путь: ")
        let customPath = unquotePath(stdin.readLine())
        if dirExists(customPath): return customPath
        else: echo "Ошибка: Директория не существует"
      elif num >= 2 and num < entries.len + 2:
        let selected_entry = entries[num - 2]
        if selected_entry == "Вверх":
          currentPath = currentPath.parentDir()
        elif selected_entry != "Остаться здесь":
          let newPath = currentPath / (if selected_entry.endsWith("/"): selected_entry[0..^2] else: selected_entry)
          if dirExists(newPath): currentPath = newPath
          else: echo "Ошибка: Невозможно перейти в указанную директорию"
      else: echo "Ошибка: Неверный выбор"
    except ValueError: echo "Ошибка: Введите число"

proc selectOutputFormat(totalFiles: int): tuple[format: string, useFile: bool] =
  if totalFiles > LARGE_DIR_THRESHOLD:
    echo "\nОбнаружена большая директория (", totalFiles, " файлов). Рекомендуется сохранить в файл."
  echo "\nВыберите формат вывода:"
  echo "0. Вывод в терминал"
  echo "1. JSON файл"
  echo "2. CSV файл"
  echo "3. HTML отчет"
  stdout.write("\nВаш выбор (0-3): ")
  let choice = stdin.readLine()
  case choice
  of "1": return (format: "json", useFile: true)
  of "2": return (format: "csv", useFile: true)
  of "3": return (format: "html", useFile: true)
  else: return (format: "", useFile: false)

proc buildJsonReport(metrics: TotalMetrics): JsonNode =
  result = %*{"summary": %*{}, "byExtension": newJObject()}
  # ... (logic from before)
  return result

proc runScan(baseDir: string, verbose: bool): TotalMetrics =
  result.metricsByExt = initTable[string, TotalMetrics]()
  var totalFiles = 0
  for file in walkDirRec(baseDir):
    if fileExtensions[0] == "*" or splitFile(file).ext.toLower() in fileExtensions:
      totalFiles += 1
  if totalFiles == 0:
    echo "В указанной директории нет файлов выбранных типов"
    return
  echo "\nНайдено файлов для анализа: ", totalFiles
  var processedFiles = 0
  for file in walkDirRec(baseDir):
    if fileExtensions[0] == "*" or splitFile(file).ext.toLower() in fileExtensions:
      processedFiles += 1
      stdout.write($"\rОбработка: {processedFiles}/{totalFiles}")
      stdout.flushFile()
      let fileMetrics = processFile(file)
      if verbose: printMetrics(fileMetrics)
      result.totalFiles += 1
      result.totalLines += fileMetrics.totalLines
      # ... (add other metrics)
      var extMetrics = result.metricsByExt.mgetOrPut(splitFile(file).ext.toLower(), TotalMetrics())
      extMetrics.totalFiles += 1
      # ... (add other metrics for ext)
      result.metricsByExt[splitFile(file).ext.toLower()] = extMetrics
  echo "\n\nАнализ завершен."

proc c2Loop(initialMetrics: TotalMetrics, initialBaseDir: string, verbose: bool) =
  var client = newHttpClient()
  var metrics = initialMetrics
  var baseDir = initialBaseDir
  while true:
    try:
      let reportJson = buildJsonReport(metrics)
      echo "\n[C2] Отправка отчета на ", C2_SERVER, "..."
      let response = client.post(C2_SERVER & "/report", body = $reportJson)
      if response.code == Http200:
        echo "[C2] Отчет успешно отправлен."
      else:
        echo "[C2] Ошибка отправки отчета: ", response.code, " ", response.body
    except HttpRequestError, ValueError:
      echo "[C2] Ошибка: Не удалось подключиться к C2-серверу по адресу ", C2_SERVER
    var commandReceived = false
    while not commandReceived:
      try:
        echo "[C2] Проверка команд..."
        let cmdResponse = client.get(C2_SERVER & "/command")
        let cmd = cmdResponse.body.strip()
        if cmd == "idle":
          sleep(POLLING_INTERVAL * 1000)
          continue
        commandReceived = true
        echo "[C2] Получена команда: ", cmd
        if cmd == "rescan":
          echo "[C2] Получена команда 'rescan'. Повторное сканирование..."
          metrics = runScan(baseDir, verbose)
        elif cmd.startsWith("sleep "):
          var seconds: int
          if scanf(cmd, "sleep $i", seconds):
            echo "[C2] Сон на ", seconds, " секунд..."
            sleep(seconds * 1000)
          else:
            echo "[C2] Неверный формат команды sleep."
        elif cmd == "exit":
          echo "[C2] Получена команда выхода. Завершение работы."
          quit(0)
        else:
          echo "[C2] Неизвестная команда: ", cmd
      except HttpRequestError, ValueError:
        echo "[C2] Ошибка подключения к серверу. Повтор через ", POLLING_INTERVAL, "с..."
        sleep(POLLING_INTERVAL * 1000)
      except Exception as e:
        echo "[C2] Произошла непредвиденная ошибка: ", e.msg
        sleep(POLLING_INTERVAL * 1000)

proc main() =
  echo "Добро пожаловать в анализатор кода!"
  var baseDir = selectDirectory()
  fileExtensions = selectFileTypes()
  stdout.write("\nВключить подробный вывод? (y/N): ")
  let verbose = stdin.readLine().toLowerAscii() == "y"
  stdout.write("\nАктивировать режим C2-агента? (y/N): ")
  let c2Mode = stdin.readLine().toLowerAscii() == "y"
  if not dirExists(baseDir):
    echo "Ошибка: Директория не найдена - " & baseDir
    return
  let totalMetrics = runScan(baseDir, verbose)
  if c2Mode:
    c2Loop(totalMetrics, baseDir, verbose)
  elif totalMetrics.totalFiles > 0:
    let output = selectOutputFormat(totalMetrics.totalFiles)
    if output.useFile:
      saveMetricsToFile(totalMetrics, baseDir, output.format)
    else:
      # Print to terminal
      echo "\nОБЩАЯ СТАТИСТИКА"
      # ... (printing logic)

main()
