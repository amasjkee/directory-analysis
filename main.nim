import os
import strutils
import tables
import parseopt
import sequtils
import times
import json
import strformat
import algorithm

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

const LARGE_DIR_THRESHOLD = 1000  # Порог количества файлов для предложения сохранения в файл
const MAX_TERMINAL_OUTPUT = 10000  # Максимальное количество строк для вывода в терминал

proc listDirectory(path: string): seq[string] =
  result = @["Вверх", "Остаться здесь"]
  for kind, name in walkDir(path):
    if kind == pcDir:
      result.add(name.extractFilename & "/")
    else:
      result.add(name.extractFilename)

proc unquotePath(s: string): string =
  ## Убирает внешние кавычки и лишние пробелы из ввода пути
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
  of ".json": "JSON"
  of ".xml": "XML"
  of ".yaml", ".yml": "YAML"
  of ".md", ".markdown": "Markdown"
  of ".txt": "Text"
  of ".doc", ".docx": "Word"
  of ".xls", ".xlsx": "Excel"
  of ".pdf": "PDF"
  of ".zip", ".rar", ".7z": "Archive"
  of ".jpg", ".jpeg", ".png", ".gif", ".bmp": "Image"
  of ".mp3", ".wav", ".ogg": "Audio"
  of ".mp4", ".avi", ".mkv": "Video"
  of ".exe", ".dll": "Binary"
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
  # Считаем строки только для текстовых файлов
  if ext in [".nim", ".nims", ".nimble", ".py", ".pyw", ".pyx", ".js", ".jsx", ".ts", ".tsx",
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

  # Универсальная статистика
  var avgSize = if metrics.totalFiles > 0: metrics.totalSize div metrics.totalFiles else: 0
  var maxSize = 0
  var minSize = metrics.totalSize
  for ext, extMetrics in metrics.metricsByExt:
    if extMetrics.totalFiles > 0:
      if extMetrics.totalSize > maxSize: maxSize = extMetrics.totalSize
      if extMetrics.totalSize < minSize: minSize = extMetrics.totalSize

  case format
  of "json":
    var json = %*{
      "summary": {
        "totalFiles": metrics.totalFiles,
        "totalSize": metrics.totalSize,
        "avgSize": avgSize,
        "maxSize": maxSize,
        "minSize": minSize,
        "totalLines": metrics.totalLines,
        "codeLines": metrics.totalCodeLines,
        "commentLines": metrics.totalCommentLines,
        "emptyLines": metrics.totalEmptyLines,
        "imports": metrics.totalImportCount
      },
      "byExtension": newJObject()
    }
    for ext, extMetrics in metrics.metricsByExt:
      json["byExtension"][ext] = %*{
        "fileType": detectFileType(ext),
        "files": extMetrics.totalFiles,
        "size": extMetrics.totalSize,
        "totalLines": extMetrics.totalLines,
        "codeLines": extMetrics.totalCodeLines,
        "commentLines": extMetrics.totalCommentLines,
        "emptyLines": extMetrics.totalEmptyLines,
        "imports": extMetrics.totalImportCount
      }
    writeFile(filename, json.pretty())

  of "csv":
    var lines = @["TotalFiles,TotalSize,AvgSize,MaxSize,MinSize,TotalLines,CodeLines,CommentLines,EmptyLines,Imports"]
    lines.add(&"{metrics.totalFiles},{metrics.totalSize},{avgSize},{maxSize},{minSize},{metrics.totalLines},{metrics.totalCodeLines},{metrics.totalCommentLines},{metrics.totalEmptyLines},{metrics.totalImportCount}")
    lines.add("")
    lines.add("Extension,FileType,Files,Size,TotalLines,CodeLines,CommentLines,EmptyLines,Imports")
    for ext, extMetrics in metrics.metricsByExt:
      lines.add(&"{ext},{detectFileType(ext)},{extMetrics.totalFiles},{extMetrics.totalSize}," &
                &"{extMetrics.totalLines},{extMetrics.totalCodeLines},{extMetrics.totalCommentLines}," &
                &"{extMetrics.totalEmptyLines},{extMetrics.totalImportCount}")
    writeFile(filename, lines.join("\n"))

  of "html":
    var html = """
<!DOCTYPE html>
<html>
<head>
    <meta charset=\"UTF-8\">
    <title>Code Metrics Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .summary { background: #f5f5f5; padding: 20px; border-radius: 5px; }
        table { border-collapse: collapse; width: 100%; margin-top: 20px; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #4CAF50; color: white; }
        tr:nth-child(even) { background-color: #f2f2f2; }
    </style>
</head>
<body>
    <h1>Code Metrics Report</h1>
    <div class=\"summary\">
        <h2>Summary</h2>
        <p>Total Files: """ & $metrics.totalFiles & """</p>
        <p>Total Size: """ & formatSize(metrics.totalSize) & """</p>
        <p>Average Size: """ & formatSize(avgSize) & """</p>
        <p>Max Size: """ & formatSize(maxSize) & """</p>
        <p>Min Size: """ & formatSize(minSize) & """</p>
        <p>Total Lines: """ & $metrics.totalLines & """</p>
        <p>Code Lines: """ & $metrics.totalCodeLines & """ (""" & safePercentage(metrics.totalCodeLines, metrics.totalLines) & """%)</p>
        <p>Comment Lines: """ & $metrics.totalCommentLines & """ (""" & safePercentage(metrics.totalCommentLines, metrics.totalLines) & """%)</p>
        <p>Empty Lines: """ & $metrics.totalEmptyLines & """ (""" & safePercentage(metrics.totalEmptyLines, metrics.totalLines) & """%)</p>
    </div>
    <h2>Details by Extension</h2>
    <table>
        <tr>
            <th>Extension</th>
            <th>Type</th>
            <th>Files</th>
            <th>Size</th>
            <th>Lines</th>
            <th>Code</th>
            <th>Comments</th>
            <th>Empty</th>
        </tr>
"""
    for ext, extMetrics in metrics.metricsByExt:
      html &= """
        <tr>
            <td>""" & ext & """</td>
            <td>""" & detectFileType(ext) & """</td>
            <td>""" & $extMetrics.totalFiles & """</td>
            <td>""" & formatSize(extMetrics.totalSize) & """</td>
            <td>""" & $extMetrics.totalLines & """</td>
            <td>""" & $extMetrics.totalCodeLines & """</td>
            <td>""" & $extMetrics.totalCommentLines & """</td>
            <td>""" & $extMetrics.totalEmptyLines & """</td>
        </tr>"""
    html &= """
    </table>
    <p><small>Generated on: """ & format(now(), "yyyy-MM-dd HH:mm:ss") & """</small></p>
</body>
</html>"""
    writeFile(filename, html)

  else: discard

  echo "\nРезультаты сохранены в файл: ", filename

proc selectFileTypes(): seq[string] =
  echo "\n=== Выберите типы файлов для анализа ===\n"
  echo "Доступные наборы:"
  echo "0. Все файлы"
  echo "1. Исходный код (.nim, .py, .js, .java, .cpp, ...)"
  echo "2. Документы (.txt, .md, .doc, .pdf, ...)"
  echo "3. Изображения (.jpg, .png, .gif, ...)"
  echo "4. Видео (.mp4, .avi, .mkv, ...)"
  echo "5. Аудио (.mp3, .wav, .ogg, ...)"
  
  stdout.write("\nВыберите набор (0-5): ")
  let choice = stdin.readLine()
  
  case choice
  of "0": @["*"]
  of "1": @[".nim", ".nims", ".nimble", ".py", ".pyw", ".pyx", ".js", ".jsx", ".ts", ".tsx",
            ".java", ".kt", ".c", ".cpp", ".h", ".hpp", ".cs", ".go", ".rs", ".rb", ".php"]
  of "2": @[".txt", ".md", ".markdown", ".doc", ".docx", ".pdf", ".rtf"]
  of "3": @[".jpg", ".jpeg", ".png", ".gif", ".bmp", ".tiff"]
  of "4": @[".mp4", ".avi", ".mkv", ".mov", ".wmv"]
  of "5": @[".mp3", ".wav", ".ogg", ".flac", ".m4a"]
  else: @["*"]

proc selectDirectory(): string =
  var currentPath = getCurrentDir()
  var selected = false
  
  while not selected:
    echo "\n=== Выберите директорию для анализа ===\n"
    echo "Текущий путь: ", currentPath
    echo "\nВарианты:"
    echo "0. Выбрать текущую директорию"
    echo "1. Ввести путь вручную"
    
    let entries = listDirectory(currentPath)
    for i, entry in entries:
      echo $(i + 2), ". ", entry

    stdout.write("\nВаш выбор (0-", entries.len + 1, "): ")
    let choice = stdin.readLine()
    
    try:
      let num = parseInt(choice)
      if num == 0:
        selected = true
        return currentPath
      elif num == 1:
        stdout.write("Введите полный путь: ")
        let rawInput = stdin.readLine()
        let customPath = unquotePath(rawInput)
        if dirExists(customPath):
          return customPath
        else:
          echo "Ошибка: Указанная директория не существует"
      elif num >= 2 and num < entries.len + 2:
        let selected_entry = entries[num - 2]
        if selected_entry == "..":
          currentPath = currentPath.parentDir()
        elif selected_entry == ".":
          discard
        else:
          let newPath = currentPath / (if selected_entry.endsWith("/"): selected_entry[0..^2] else: selected_entry)
          if dirExists(newPath):
            currentPath = newPath
          else:
            echo "Ошибка: Невозможно перейти в указанную директорию"
      else:
        echo "Ошибка: Неверный выбор"
    except ValueError:
      echo "Ошибка: Введите число"
    
    echo "\nНажмите Enter для продолжения..."
    discard stdin.readLine()



proc selectOutputFormat(totalFiles: int): tuple[format: string, useFile: bool] =
  # Всегда предлагаем варианты вывода: в терминал или в файл (json/csv/html).
  if totalFiles > LARGE_DIR_THRESHOLD:
    echo "\nОбнаружена большая директория (", totalFiles, " файлов)"
    echo "Рекомендуется сохранить результаты в файл"

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

proc main() =
  echo "Добро пожаловать в анализатор кода!"
  let baseDir = selectDirectory()
  var scanDirs: seq[string] = @[]
  var verbose = false
  fileExtensions = selectFileTypes()

  stdout.write("\nВключить подробный вывод? (y/N): ")
  verbose = stdin.readLine().toLowerAscii() == "y"
  
  if not dirExists(baseDir):
    echo "Ошибка: Директория не найдена - " & baseDir
    return

  scanDirs.add(baseDir)
  var totalMetrics: TotalMetrics
  totalMetrics.metricsByExt = initTable[string, TotalMetrics]()

  # Сначала подсчитаем общее количество файлов для прогресс-бара
  var totalFiles = 0
  echo "\nПодсчет файлов..."
  for file in walkDirRec(baseDir):
    let ext = splitFile(file).ext.toLower()
    if fileExtensions[0] == "*" or ext in fileExtensions:
      totalFiles += 1

  if totalFiles == 0:
    echo "В указанной директории нет файлов выбранных типов"
    return

  let output = selectOutputFormat(totalFiles)
  # Если выбран экспорт в файл, отключаем подробный вывод в терминал
  if output.useFile:
    if verbose:
      echo "\nПодробный вывод отключен, т.к. результаты будут сохранены в файл."
    verbose = false
  
  var processedFiles = 0
  echo "\nОбработка файлов:"
  for file in walkDirRec(baseDir):
    let ext = splitFile(file).ext.toLower()
    if fileExtensions[0] == "*" or ext in fileExtensions:
      processedFiles += 1
      # Показываем прогресс (пропускаем, если сохраняем в файл)
      if not output.useFile:
        stdout.write("\r[")
        let progress = processedFiles * 50 div totalFiles
        for i in 0..<50:
          if i < progress:
            stdout.write("#")
          else:
            stdout.write(" ")
        stdout.write("] " & $(processedFiles * 100 div totalFiles) & "% ")
        stdout.write("(" & $processedFiles & "/" & $totalFiles & ")    ")
        stdout.flushFile()

      let fileMetrics = processFile(file)
      if verbose:
        echo "\n"  # Новая строка для подробного вывода
        printMetrics(fileMetrics)

      totalMetrics.totalFiles += 1
      totalMetrics.totalLines += fileMetrics.totalLines
      totalMetrics.totalCodeLines += fileMetrics.codeLines
      totalMetrics.totalCommentLines += fileMetrics.commentLines
      totalMetrics.totalEmptyLines += fileMetrics.emptyLines
      totalMetrics.totalImportCount += fileMetrics.importCount
      totalMetrics.totalSize += fileMetrics.fileSize

      var extMetrics = totalMetrics.metricsByExt.mgetOrPut(ext, TotalMetrics())
      extMetrics.totalFiles += 1
      extMetrics.totalLines += fileMetrics.totalLines
      extMetrics.totalCodeLines += fileMetrics.codeLines
      extMetrics.totalCommentLines += fileMetrics.commentLines
      extMetrics.totalEmptyLines += fileMetrics.emptyLines
      extMetrics.totalImportCount += fileMetrics.importCount
      extMetrics.totalSize += fileMetrics.fileSize
      totalMetrics.metricsByExt[ext] = extMetrics

  echo "\n"  # Новая строка после прогресс-бара
  
  if output.useFile:
    saveMetricsToFile(totalMetrics, baseDir, output.format)
    return

  # Универсальная статистика для любых файлов
  echo "\n============================================"
  echo "          ОБЩАЯ СТАТИСТИКА"
  echo "============================================"
  echo "Всего файлов: " & $totalMetrics.totalFiles
  echo "Общий размер: " & formatSize(totalMetrics.totalSize)
  if totalMetrics.totalFiles > 0:
    echo "Средний размер файла: " & formatSize(totalMetrics.totalSize div totalMetrics.totalFiles)
    var maxSize = 0
    var minSize = totalMetrics.totalSize
    for ext, metrics in totalMetrics.metricsByExt:
      if metrics.totalFiles > 0:
        if metrics.totalSize > maxSize: maxSize = metrics.totalSize
        if metrics.totalSize < minSize: minSize = metrics.totalSize
    echo "Самый большой файл: " & formatSize(maxSize)
    echo "Самый маленький файл: " & formatSize(minSize)

  if totalMetrics.totalLines > 0:
    let codePercent = safePercentage(totalMetrics.totalCodeLines, totalMetrics.totalLines)
    let commentPercent = safePercentage(totalMetrics.totalCommentLines, totalMetrics.totalLines)
    let emptyPercent = safePercentage(totalMetrics.totalEmptyLines, totalMetrics.totalLines)
    echo "  - Код: " & $totalMetrics.totalCodeLines & " (" & codePercent & "%)"
    echo "  - Комментарии: " & $totalMetrics.totalCommentLines & " (" & commentPercent & "%)"
    echo "  - Пустые: " & $totalMetrics.totalEmptyLines & " (" & emptyPercent & "%)"
    echo "Всего импортов: " & $totalMetrics.totalImportCount

  if totalMetrics.metricsByExt.len > 0:
    echo "\n--- Статистика по расширениям ---"
    var sortedExts = toSeq(totalMetrics.metricsByExt.pairs)
    sortedExts.sort(proc(x, y: (string, TotalMetrics)): int = cmp(y[1].totalFiles, x[1].totalFiles))
    for (ext, metrics) in sortedExts:
      let fileType = detectFileType(ext)
      echo "\nРасширение: " & ext & " (" & fileType & ")"
      echo "    - Файлов: " & $metrics.totalFiles
      echo "    - Размер: " & formatSize(metrics.totalSize)
      if metrics.totalLines > 0:
        echo "    - Строк: " & $metrics.totalLines & 
             " (код: " & $metrics.totalCodeLines & ", комментарии: " & $metrics.totalCommentLines & ", пустые: " & $metrics.totalEmptyLines & ")"

main()